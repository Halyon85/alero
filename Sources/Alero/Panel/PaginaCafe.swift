import SwiftUI

// Alero › Café: prender o apagar el café a mano y sus opciones (pausar al bloquear, dejar apagar la pantalla, tapa cerrada).

struct PaginaCafe: View {
    @ObservedObject private var ajustes = Ajustes.shared
    @ObservedObject private var cafe = Cafe.shared
    @State private var permisoGuardado = CafeTapa.permisoGuardado

    private let duraciones: [(String, TimeInterval?)] = [
        (T("30 min", "30 min"), 30 * 60), (T("1 h", "1 h"), 3600), (T("2 h", "2 h"), 7200), (T("Sin fin", "No limit"), nil),
    ]

    var body: some View {
        TituloPagina(titulo: T("Café", "Coffee"),
                     subtitulo: T("Mantiene la Mac despierta. También desde el notch y el menú de la barra.",
                                  "Keeps your Mac awake. Also from the notch and the menu bar."))
        Tarjeta {
            Fila(titulo: cafe.prendido ? T("Prendido", "On") : T("Apagado", "Off"),
                 detalle: cafe.prendido ? cafe.descripcion : T("La Mac duerme cuando le toca.", "Your Mac sleeps as usual."), divisor: false) {
                if cafe.prendido {
                    BotonSecundario(texto: T("Apagar", "Turn off"), icono: "cup.and.saucer") { cafe.apagar() }
                } else {
                    ForEach(duraciones, id: \.0) { nombre, segundos in
                        BotonSecundario(texto: nombre) { cafe.prender(por: segundos) }
                    }
                }
            }
        }
        Tarjeta(titulo: T("Opciones", "Options")) {
            FilaLlave(titulo: T("Pausar con la pantalla bloqueada", "Pause while locked"),
                      detalle: T("Si bloqueás la Mac, deja que duerma; al volver sigue.", "If you lock the Mac it may sleep; it resumes when you're back."),
                      valor: $ajustes.cafePausarAlBloquear)
            FilaLlave(titulo: T("Dejar que se apague la pantalla", "Let the display sleep"),
                      detalle: T("La Mac sigue despierta (descargas, música) pero la pantalla se apaga sola.",
                                 "The Mac stays awake (downloads, music) but the display turns off."),
                      valor: $ajustes.cafeDejarApagarPantalla)
                .onChange(of: ajustes.cafeDejarApagarPantalla) { _, _ in cafe.ajustesCambiaron() }
            FilaLlave(titulo: T("También con la tapa cerrada", "Also with the lid closed"),
                      detalle: T("La primera vez macOS pide tu contraseña (después ya no). Al apagar el café o cerrar Alero vuelve a la normalidad solo. Ojo: cerrada en un bolso, la Mac se calienta.",
                                 "The first time macOS asks for your password (not after that). Turning coffee off or quitting Alero restores it. Careful: closed in a bag, the Mac gets hot."),
                      divisor: !permisoGuardado, valor: $ajustes.cafeTapaCerrada)
                .onChange(of: ajustes.cafeTapaCerrada) { _, prender in
                    prender ? cafe.prenderTapa() : CafeTapa.apagar()
                    // La primera vez se guarda el permiso: se vuelve a mirar cuando termina.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { permisoGuardado = CafeTapa.permisoGuardado }
                }
            if permisoGuardado {
                Fila(titulo: T("Permiso guardado", "Permission saved"),
                     detalle: T("macOS ya no pide la contraseña para esto. Solo sirve para no dormirse con la tapa cerrada.",
                                "macOS no longer asks for the password for this. It only covers not sleeping with the lid closed."),
                     divisor: false) {
                    BotonSecundario(texto: T("Quitar", "Remove")) {
                        ajustes.cafeTapaCerrada = false
                        CafeTapa.quitarPermiso { _ in permisoGuardado = CafeTapa.permisoGuardado }
                    }
                }
            }
        }
    }
}
