import AppKit
import IOKit.pwr_mgt

// Café: mantiene la Mac despierta con la función oficial de macOS (aserciones de energía), por un rato o sin fin.
// No toca nada del sistema: al apagarlo, o si Alero se cierra, macOS vuelve solo a su comportamiento normal.
// Con la opción "También con la tapa cerrada", además pide la contraseña para que no se duerma al cerrarla (ver
// `CafeTapa`, que lo vuelve a la normalidad solo).

final class Cafe: ObservableObject {
    static let shared = Cafe()

    @Published private(set) var prendido = false
    /// Hasta cuándo dura; nil = sin fin.
    @Published private(set) var hasta: Date?

    private var asercionSistema: IOPMAssertionID = 0
    private var asercionPantalla: IOPMAssertionID = 0
    private var reloj: Timer?
    private var pausadoPorBloqueo = false
    private var observadores: [NSObjectProtocol] = []

    private init() {
        let centro = DistributedNotificationCenter.default()
        observadores.append(centro.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.alBloquear()
        })
        observadores.append(centro.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.alDesbloquear()
        })
    }

    /// Prende el café por `segundos` (nil = sin fin). Si ya estaba prendido, reemplaza la duración.
    func prender(por segundos: TimeInterval?) {
        reloj?.invalidate()
        reloj = nil
        hasta = segundos.map { Date().addingTimeInterval($0) }
        if let fin = hasta {
            let timer = Timer(fire: fin, interval: 0, repeats: false) { [weak self] _ in self?.apagar() }
            RunLoop.main.add(timer, forMode: .common)
            reloj = timer
        }
        prendido = true
        pausadoPorBloqueo = false
        tomarAserciones()
        if Ajustes.shared.cafeTapaCerrada { prenderTapa() }
    }

    /// La parte de la tapa cerrada. Si se cancela la contraseña, el café sigue prendido igual (sin la tapa) y se avisa.
    func prenderTapa() {
        guard prendido, !CafeTapa.prendido else { return }
        CafeTapa.prender { bien in
            if !bien { ControladorNotch.shared.avisar(.permiso(nombre: T("Café con tapa cerrada", "Coffee with lid closed"))) }
        }
    }

    func apagar() {
        reloj?.invalidate()
        reloj = nil
        hasta = nil
        prendido = false
        pausadoPorBloqueo = false
        soltarAserciones()
        CafeTapa.apagar()
    }

    func alternar() {
        prendido ? apagar() : prender(por: nil)
    }

    /// Vuelve a tomar las aserciones con la opción "dejar que se apague la pantalla" nueva.
    func ajustesCambiaron() {
        guard prendido, !pausadoPorBloqueo else { return }
        tomarAserciones()
    }

    var descripcion: String {
        guard prendido else { return T("Apagado", "Off") }
        guard let fin = hasta else { return T("Sin fin", "Until turned off") }
        let hora = fin.formatted(date: .omitted, time: .shortened)
        return T("Hasta las \(hora)", "Until \(hora)")
    }

    // MARK: - Aserciones

    private func tomarAserciones() {
        soltarAserciones()
        let motivo = "Alero: café prendido" as CFString
        let nivel = IOPMAssertionLevel(kIOPMAssertionLevelOn)
        let sistema = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, nivel, motivo, &asercionSistema)
        if sistema != kIOReturnSuccess {
            NSLog("Alero: no se pudo evitar el reposo (código \(sistema))")
        }
        guard !Ajustes.shared.cafeDejarApagarPantalla else { return }
        let pantalla = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, nivel, motivo, &asercionPantalla)
        if pantalla != kIOReturnSuccess {
            NSLog("Alero: no se pudo mantener la pantalla prendida (código \(pantalla))")
        }
    }

    private func soltarAserciones() {
        if asercionSistema != 0 { IOPMAssertionRelease(asercionSistema); asercionSistema = 0 }
        if asercionPantalla != 0 { IOPMAssertionRelease(asercionPantalla); asercionPantalla = 0 }
    }

    // Con la pantalla bloqueada no tiene sentido mantener la Mac despierta: se suelta y se retoma al desbloquear.
    private func alBloquear() {
        guard prendido, Ajustes.shared.cafePausarAlBloquear else { return }
        pausadoPorBloqueo = true
        soltarAserciones()
    }

    private func alDesbloquear() {
        guard prendido, pausadoPorBloqueo else { return }
        pausadoPorBloqueo = false
        tomarAserciones()
    }
}
