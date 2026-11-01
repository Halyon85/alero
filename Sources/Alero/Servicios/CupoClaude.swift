import Foundation

// El cupo de Claude Code (las ventanas de 5 horas y de 7 días) para el espacio Agentes del notch. Claude Code no lo
// guarda en sus registros: se lo pasa a su "barra de estado", un comando que corre en cada respuesta. Conectar pone
// ahí un script de Alero que guarda lo que recibe en `claude-estado.json` y después le pasa lo mismo a la barra que
// había antes (si había una), así esa sigue andando. Sin claves ni internet. Agregado el
// 01/11/2026. Desconectar vuelve a dejar la barra anterior. Antes de cambiar `~/.claude/settings.json` se guarda una
// copia en la carpeta de Alero.

enum CupoClaude {
    static let carpeta = NSHomeDirectory() + "/Library/Application Support/Alero"
    static let estado = carpeta + "/claude-estado.json"
    private static let script = carpeta + "/barra-claude.sh"
    private static let anterior = carpeta + "/barra-anterior.txt"
    private static let respaldo = carpeta + "/claude-settings-respaldo.json"
    private static let ajustesClaude = NSHomeDirectory() + "/.claude/settings.json"

    /// Si la barra de estado de Claude Code es la de Alero.
    static var conectado: Bool { (leerAjustes()?["statusLine"] as? [String: Any])?["command"] as? String == comando }

    private static var comando: String { "/bin/sh \"\(script)\"" }

    /// Pone la barra de Alero (guardando la anterior). Devuelve un error para mostrar, o nil si salió bien.
    static func conectar() -> String? {
        guard var ajustes = leerAjustes() else { return T("No se pudo leer la configuración de Claude Code.", "Couldn't read Claude Code's settings.") }
        do {
            try FileManager.default.createDirectory(atPath: carpeta, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: ajustesClaude, toPath: respaldo + ".tmp")
            _ = try? FileManager.default.removeItem(atPath: respaldo)
            try FileManager.default.moveItem(atPath: respaldo + ".tmp", toPath: respaldo)
            if let previo = (ajustes["statusLine"] as? [String: Any])?["command"] as? String, previo != comando {
                try previo.write(toFile: anterior, atomically: true, encoding: .utf8)
            }
            try contenidoScript.write(toFile: script, atomically: true, encoding: .utf8)
            ajustes["statusLine"] = ["type": "command", "command": comando]
            try escribirAjustes(ajustes)
            return nil
        } catch {
            return T("No se pudo conectar: \(error.localizedDescription)", "Couldn't connect: \(error.localizedDescription)")
        }
    }

    /// Vuelve a dejar la barra que había antes (o ninguna). Devuelve un error para mostrar, o nil.
    static func desconectar() -> String? {
        guard var ajustes = leerAjustes() else { return T("No se pudo leer la configuración de Claude Code.", "Couldn't read Claude Code's settings.") }
        if let previo = try? String(contentsOfFile: anterior, encoding: .utf8), !previo.isEmpty {
            ajustes["statusLine"] = ["type": "command", "command": previo]
        } else {
            ajustes.removeValue(forKey: "statusLine")
        }
        do {
            try escribirAjustes(ajustes)
            _ = try? FileManager.default.removeItem(atPath: estado)
            return nil
        } catch {
            return T("No se pudo desconectar: \(error.localizedDescription)", "Couldn't disconnect: \(error.localizedDescription)")
        }
    }

    /// El script de la barra: guarda lo que manda Claude Code (solo para Alero, permisos 600) y lo pasa a la barra
    /// anterior. Si la anterior ya no existe (por ejemplo, se desinstaló la herramienta que la puso), no muestra nada y no falla.
    private static var contenidoScript: String {
        """
        #!/bin/sh
        # Barra de estado de Claude Code puesta por Alero: guarda el cupo para el notch y deja pasar la barra anterior.
        carpeta="$HOME/Library/Application Support/Alero"
        entrada=$(cat)
        umask 077
        printf '%s' "$entrada" > "$carpeta/claude-estado.json.tmp" && mv "$carpeta/claude-estado.json.tmp" "$carpeta/claude-estado.json"
        if [ -s "$carpeta/barra-anterior.txt" ]; then
          printf '%s' "$entrada" | /bin/sh -c "$(cat "$carpeta/barra-anterior.txt")" 2>/dev/null
        fi
        exit 0

        """
    }

    private static func leerAjustes() -> [String: Any]? {
        guard let datos = FileManager.default.contents(atPath: ajustesClaude) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any]
    }

    private static func escribirAjustes(_ ajustes: [String: Any]) throws {
        let datos = try JSONSerialization.data(withJSONObject: ajustes, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try datos.write(to: URL(fileURLWithPath: ajustesClaude), options: .atomic)
    }
}

extension ReglasAgentes {
    /// Los cupos que Claude Code pasa a su barra de estado: `rate_limits.five_hour` y `seven_day`, con
    /// `used_percentage` (0–100) y `resets_at` (segundos desde 1970 o fecha ISO).
    static func cuposClaude(en datos: Data) -> [EstadoAgente.Cupo] {
        guard let objeto = (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any],
              let limites = objeto["rate_limits"] as? [String: Any] else { return [] }
        let ventanas: [(clave: String, nombre: String)] = [("five_hour", T("5 h", "5 h")), ("seven_day", T("semana", "week"))]
        return ventanas.compactMap { ventana in
            guard let datos = limites[ventana.clave] as? [String: Any],
                  let usado = (datos["used_percentage"] as? Double) ?? (datos["used_percentage"] as? Int).map(Double.init) else { return nil }
            return EstadoAgente.Cupo(nombre: ventana.nombre, usado: usado / 100, reinicia: fecha(datos["resets_at"]))
        }
    }

    private static func fecha(_ valor: Any?) -> Date? {
        if let segundos = valor as? Double { return Date(timeIntervalSince1970: segundos) }
        if let segundos = valor as? Int { return Date(timeIntervalSince1970: Double(segundos)) }
        if let texto = valor as? String { return ISO8601DateFormatter().date(from: texto) }
        return nil
    }
}
