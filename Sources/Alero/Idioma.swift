import Foundation

// Textos en castellano o inglés según el idioma de la Mac. Cada texto se escribe una vez, en los dos idiomas,
// donde se usa: T("Guardar", "Save").

enum Idioma {
    /// Se decide una sola vez al arrancar: cambiar el idioma de la Mac pide reabrir la app, como en el resto de macOS.
    static let castellano: Bool = (Locale.preferredLanguages.first ?? "es").hasPrefix("es")
}

func T(_ es: String, _ en: String) -> String {
    Idioma.castellano ? es : en
}
