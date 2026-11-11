import AppKit
import EventKit
import SwiftUI

// Próximos eventos del calendario de la Mac (los de todas las cuentas que tenga Calendario: iCloud, Google…).
// Se actualiza solo cuando algo cambia (eventos, cambio de día, de hora o de zona) y con un único reloj hasta el
// próximo inicio o fin: no consulta a cada rato. Avisa 5 minutos antes de cada evento con hora.

struct Evento: Identifiable, Equatable {
    let id: String
    let titulo: String
    let inicio: Date
    let fin: Date
    let todoElDia: Bool
    let color: Color
    /// Link de la reunión (Meet, Zoom, Teams…) si aparece en el evento.
    let enlace: URL?
}

/// Un calendario de la Mac, para elegir en Ajustes cuáles se muestran.
struct CalendarioDisponible: Identifiable, Equatable {
    let id: String
    let titulo: String
    /// La cuenta de donde viene (iCloud, Google…).
    let cuenta: String
    let color: Color
}

final class Calendario: ObservableObject {
    static let shared = Calendario()

    enum Permiso { case sinPedir, concedido, denegado }

    @Published private(set) var eventos: [Evento] = []
    @Published private(set) var permiso: Permiso = .sinPedir
    /// Todos los calendarios de la Mac, ordenados por cuenta y nombre. Lo muestra Alero › Notch para elegir.
    @Published private(set) var calendarios: [CalendarioDisponible] = []

    /// Se llama 5 minutos antes de un evento con hora (una sola vez por evento).
    var alAcercarse: ((Evento) -> Void)?

    /// Recién al usarlo: crearlo conecta con la base de Calendario de macOS, y el singleton existe aunque el
    /// calendario esté apagado (el notch y Ajustes lo miran). Se crea siempre en el hilo principal (ver `recargar`).
    private lazy var almacen = EKEventStore()
    private let cola = DispatchQueue(label: "alero.calendario")
    private var reloj: Timer?
    private var avisados = Set<String>()
    private var observadores: [NSObjectProtocol] = []
    private var arrancado = false

    func arrancar() {
        guard !arrancado else { return }
        arrancado = true
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: permiso = .concedido; empezar()
        case .notDetermined: pedirPermiso()
        default: permiso = .denegado
        }
    }

    /// Relee el permiso (macOS no avisa cuando lo das en Ajustes del Sistema). Lo llaman los ajustes y el notch al abrirse.
    func revisarPermiso() {
        let ahora: Permiso
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: ahora = .concedido
        case .notDetermined: ahora = .sinPedir
        default: ahora = .denegado
        }
        guard ahora != permiso else { return }
        permiso = ahora
        // Solo si el calendario ya arrancó (notch y calendario prendidos): con el calendario apagado, mirar el permiso
        // desde Ajustes › General no tiene que conectarse a Calendario (auditoría del 01/11/2026).
        if ahora == .concedido, arrancado { empezar() }
    }

    static func abrirAjustesDePrivacidad() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func pedirPermiso() {
        // Alero no tiene ventana al frente: sin activarla, el cartel de macOS puede quedar detrás de otras apps.
        NSApp.activate(ignoringOtherApps: true)
        almacen.requestFullAccessToEvents { [weak self] concedido, error in
            if let error { NSLog("Alero: el calendario no respondió al pedir permiso: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                self?.permiso = concedido ? .concedido : .denegado
                if concedido { self?.empezar() }
            }
        }
    }

    func abrirEnCalendario(_ evento: Evento) {
        // `ical://` abre Calendario en ese día; el link de reunión, si hay, se abre aparte con su botón.
        let segundos = Int(evento.inicio.timeIntervalSinceReferenceDate)
        if let url = URL(string: "ical://ekevent/\(evento.id)?method=show&options=more&date=\(segundos)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func empezar() {
        guard observadores.isEmpty else { recargar(); return }
        let centro = NotificationCenter.default
        let nombres: [Notification.Name] = [.EKEventStoreChanged, .NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange]
        for nombre in nombres {
            observadores.append(centro.addObserver(forName: nombre, object: nil, queue: .main) { [weak self] _ in self?.recargar() })
        }
        let espacio = NSWorkspace.shared.notificationCenter
        observadores.append(espacio.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recargar()
        })
        recargar()
    }

    /// Lee de ahora al final de mañana (máx. 6 eventos). EventKit puede tardar: se lee fuera del hilo principal.
    func recargar() {
        guard permiso == .concedido else { return }
        // Se toma acá, en el hilo principal: si se creara recién dentro de la cola, dos hilos podrían crearlo a la vez.
        let almacen = self.almacen
        let ocultos = Set(Ajustes.shared.calendariosOcultos)
        cola.async { [weak self] in
            guard let self else { return }
            let ahora = Date()
            let calendario = Foundation.Calendar.current
            let finDeManana = calendario.date(byAdding: .day, value: 2, to: calendario.startOfDay(for: ahora)) ?? ahora.addingTimeInterval(172_800)
            let todos = almacen.calendars(for: .event)
            let disponibles = todos.map {
                CalendarioDisponible(id: $0.calendarIdentifier, titulo: $0.title, cuenta: $0.source?.title ?? "", color: Color(cgColor: $0.cgColor))
            }.sorted { ($0.cuenta, $0.titulo) < ($1.cuenta, $1.titulo) }
            let filtro = almacen.predicateForEvents(withStart: ahora, end: finDeManana, calendars: nil)
            let leidos = almacen.events(matching: filtro)
                .filter { $0.endDate > ahora && $0.status != .canceled }
                .filter { Calendario.seMuestra($0.calendar?.calendarIdentifier, ocultos: ocultos) }
                .sorted { $0.startDate < $1.startDate }
                .prefix(6)
                .map(Calendario.evento(de:))
            DispatchQueue.main.async {
                if self.calendarios != disponibles { self.calendarios = disponibles }
                self.eventos = Array(leidos)
                self.programarReloj()
            }
        }
    }

    /// Si los eventos de ese calendario se muestran: todos menos los que la persona apagó. Un evento sin calendario
    /// (no debería pasar) se muestra. Sin estado: se prueba en `CalendarioTests`.
    static func seMuestra(_ calendario: String?, ocultos: Set<String>) -> Bool {
        guard let calendario else { return true }
        return !ocultos.contains(calendario)
    }

    /// Prende o apaga un calendario y relee los eventos. Lo llama Alero › Notch. Hilo principal.
    func mostrar(_ id: String, _ visible: Bool) {
        var ocultos = Ajustes.shared.calendariosOcultos.filter { $0 != id }
        if !visible { ocultos.append(id) }
        Ajustes.shared.calendariosOcultos = ocultos
        recargar()
    }

    // Un solo reloj: al próximo "5 minutos antes", inicio o fin, lo que llegue primero. Ahí se relee todo.
    private func programarReloj() {
        reloj?.invalidate()
        let ahora = Date()
        avisarSiCorresponde(ahora)
        let marcas = eventos.flatMap { evento -> [Date] in
            evento.todoElDia ? [evento.fin] : [evento.inicio.addingTimeInterval(-300), evento.inicio, evento.fin]
        }
        guard let proxima = marcas.filter({ $0 > ahora }).min() else { return }
        let timer = Timer(fire: proxima.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in self?.recargar() }
        RunLoop.main.add(timer, forMode: .common)
        reloj = timer
    }

    private func avisarSiCorresponde(_ ahora: Date) {
        // Una vez arrancado, el calendario sigue leyendo aunque se apague la opción: el aviso mira la opción de ahora.
        let prendido = Ajustes.shared.notchActivo && Ajustes.shared.notchCalendario
        for evento in Calendario.porAvisar(eventos, avisados: avisados, ahora: ahora, prendido: prendido) {
            avisados.insert(evento.id)
            alAcercarse?(evento)
        }
    }

    /// Los eventos con hora que empiezan en 5 minutos o menos (o empezaron hace menos de 1) y no se avisaron todavía.
    /// Con el calendario del notch apagado, ninguno. Sin estado: se prueba en `CalendarioTests`.
    static func porAvisar(_ eventos: [Evento], avisados: Set<String>, ahora: Date, prendido: Bool) -> [Evento] {
        guard prendido else { return [] }
        return eventos.filter { evento in
            guard !evento.todoElDia, !avisados.contains(evento.id) else { return false }
            let falta = evento.inicio.timeIntervalSince(ahora)
            return falta <= 300 && falta > -60
        }
    }

    private static let buscadorEnlaces = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"']*(meet\.google\.com|zoom\.us|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|"#
            + #"facetime\.apple\.com)[^\s<>"']*"#,
        options: [.caseInsensitive])

    private static func evento(de evento: EKEvent) -> Evento {
        let textos = [evento.url?.absoluteString, evento.location, evento.notes].compactMap { $0 }.joined(separator: " ")
        let rango = NSRange(textos.startIndex..., in: textos)
        let enlace = buscadorEnlaces?.firstMatch(in: textos, range: rango)
            .flatMap { Range($0.range, in: textos) }
            .flatMap { URL(string: String(textos[$0])) }
        let color = evento.calendar.map { Color(cgColor: $0.cgColor) } ?? Tema.acento
        return Evento(id: evento.eventIdentifier ?? UUID().uuidString,
                      titulo: evento.title ?? T("Sin título", "Untitled"),
                      inicio: evento.startDate, fin: evento.endDate, todoElDia: evento.isAllDay,
                      color: color, enlace: enlace)
    }
}
