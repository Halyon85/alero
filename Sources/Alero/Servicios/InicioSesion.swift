import Foundation
import ServiceManagement

// «Abrir al iniciar sesión» siempre tiene que abrir ESTA copia de Alero, la instalada en Aplicaciones.
// macOS guarda la ruta de la copia que prendió la opción y no la cambia sola: si Alero se prendió desde otra carpeta
// (una copia de prueba, otro disco) y después se instaló en Aplicaciones, al prender la Mac seguía abriendo la otra.
// Si esa copia tiene otra firma, macOS la toma por una app distinta y vuelve a pedir todos los permisos
// (pasó el 17/11/2026: arrancaba una 0.1.4 vieja desde un disco de respaldo).
// Acá se anota desde qué ruta se registró el arranque y, si no es la de esta copia, se registra de nuevo.

enum InicioSesion {
    /// La ruta de la copia que registró el arranque por última vez.
    static let claveRuta = "app.inicioRegistradoEn"
    /// Queda prendida mientras se está registrando de nuevo: si la app se cierra en el medio, se termina al volver.
    static let clavePendiente = "app.inicioPendiente"

    /// Solo una copia instalada corrige el arranque. Una de prueba (la carpeta `build` del proyecto) no, para que
    /// compilar y probar no le saque el arranque a la instalada.
    static func estaInstalada(_ ruta: String, casa: String = NSHomeDirectory()) -> Bool {
        ruta.hasPrefix("/Applications/") || ruta.hasPrefix(casa + "/Applications/")
    }

    /// Si hay que registrar el arranque de nuevo: está prendido, esta copia es la instalada y lo registró otra
    /// (o no se sabe cuál, que es el caso de quien viene de una versión anterior a la 0.1.7).
    static func hayQueCorregir(prendido: Bool, ruta: String, registradaEn: String?, casa: String = NSHomeDirectory()) -> Bool {
        prendido && estaInstalada(ruta, casa: casa) && registradaEn != ruta
    }

    /// Lo llama el arranque de la app. Main thread. Si macOS no deja registrar, queda anotado en el registro y se
    /// reintenta en el próximo arranque (la ruta se guarda recién cuando salió bien).
    static func revisar() {
        let guardado = UserDefaults.standard
        let ruta = Bundle.main.bundlePath
        let pendiente = guardado.bool(forKey: clavePendiente)
        let prendido = SMAppService.mainApp.status == .enabled
        let corregir = hayQueCorregir(prendido: prendido, ruta: ruta, registradaEn: guardado.string(forKey: claveRuta))
        guard corregir || (pendiente && estaInstalada(ruta)) else { return }
        do {
            // A propósito en este orden: macOS solo cambia la ruta al registrar de cero. La marca de pendiente cubre
            // el caso de que se saque el registro y no se llegue a poner el nuevo.
            guardado.set(true, forKey: clavePendiente)
            if prendido { try SMAppService.mainApp.unregister() }
            try SMAppService.mainApp.register()
            guardado.set(false, forKey: clavePendiente)
            guardado.set(ruta, forKey: claveRuta)
        } catch {
            NSLog("Alero: no se pudo corregir el arranque al iniciar sesión: \(error.localizedDescription)")
        }
    }

    /// Lo llama Ajustes › General cuando la persona cambia la opción a mano.
    static func anotar(prendido: Bool) {
        let guardado = UserDefaults.standard
        guardado.set(false, forKey: clavePendiente)
        if prendido { guardado.set(Bundle.main.bundlePath, forKey: claveRuta) } else { guardado.removeObject(forKey: claveRuta) }
    }
}
