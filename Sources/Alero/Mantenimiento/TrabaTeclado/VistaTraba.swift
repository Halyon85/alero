import AppKit
import SwiftUI

// La capa del modo limpieza: negra (así se ven mejor las marcas de la pantalla), con qué está trabado y las dos
// formas de salir: 5 Esc seguidos (las teclas se van prendiendo) o mantener apretado el botón hasta que se llena.
// Se sale al soltar, no al llegar: así el clic termina en la capa y no en la app de abajo.

struct VistaTraba: View {
    @ObservedObject var estado: EstadoTraba
    let salir: () -> Void

    /// Los Esc que se ven prendidos (se apagan solos si pasa la pausa máxima sin otro Esc).
    @State private var mostrados = 0
    @State private var marca = 0
    @State private var progreso: CGFloat = 0
    @State private var apretando = false
    @State private var armado = false
    @State private var armar: DispatchWorkItem?

    private let tiempoBoton: TimeInterval = 1.2

    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Tema.acento.opacity(0.12), .clear], center: .top, startRadius: 0, endRadius: 640)
            VStack(spacing: 32) {
                ZStack {
                    Circle().fill(Tema.acentoFondo)
                    Image(systemName: "keyboard").font(.system(size: 34, weight: .regular)).foregroundStyle(Tema.acento)
                }
                .frame(width: 84, height: 84)
                VStack(spacing: 10) {
                    Text(T("Teclado trabado", "Keyboard locked")).font(.system(size: 34, weight: .semibold)).foregroundStyle(Tema.textoNotch)
                    Text(T("Limpiá tranquilo: el teclado, el trackpad y las teclas de brillo, volumen y música no hacen nada.",
                           "Clean away: the keyboard, the trackpad and the brightness, volume and media keys do nothing."))
                        .font(.system(size: 16)).foregroundStyle(Tema.textoNotchSuave)
                        .multilineTextAlignment(.center).frame(maxWidth: 480)
                }
                tarjetaSalida
                if let fin = estado.fin {
                    (Text(T("Se destraba sola en ", "Unlocks by itself in ")) + Text(timerInterval: Date()...fin, countsDown: true))
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(Tema.textoNotchSuave.opacity(0.8))
                }
            }
            .padding(32)
        }
        .ignoresSafeArea()
        .onReceive(estado.$escs.dropFirst()) { cuenta in
            withAnimation(.spring(duration: 0.25, bounce: 0.3)) { mostrados = cuenta }
            marca += 1
        }
        .task(id: marca) {
            guard mostrados > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(SalidaTraba.pausaMaxima * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { mostrados = 0 }
        }
    }

    private var tarjetaSalida: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(T("PARA SALIR", "TO EXIT")).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Tema.textoNotchSuave)
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(0..<SalidaTraba.necesarios, id: \.self) { i in
                        let prendida = i < mostrados
                        Text("esc").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(prendida ? Color.black : Tema.textoNotchSuave)
                            .frame(width: 38, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(prendida ? Tema.acento : Tema.rellenoNotch))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(prendida ? .clear : Tema.bordeNotch))
                            .scaleEffect(prendida ? 1.06 : 1)
                    }
                }
                Text(T("Apretá Esc 5 veces seguidas", "Press Esc 5 times in a row")).font(.system(size: 14)).foregroundStyle(Tema.textoNotch)
            }
            HStack(spacing: 10) {
                Rectangle().fill(Tema.bordeNotch).frame(height: 1)
                Text(T("o", "or")).font(.system(size: 12)).foregroundStyle(Tema.textoNotchSuave)
                Rectangle().fill(Tema.bordeNotch).frame(height: 1)
            }
            botonMantener
        }
        .padding(24)
        .frame(width: 500)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: NSColor(hex: 0x111114))))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Tema.bordeNotch))
    }

    private var botonMantener: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Tema.rellenoNotch)
            GeometryReader { lugar in
                Capsule().fill(Tema.acento).frame(width: max(52, lugar.size.width * progreso)).opacity(progreso > 0 ? 1 : 0)
            }
            HStack(spacing: 8) {
                Image(systemName: armado ? "lock.open.fill" : "hand.tap.fill").font(.system(size: 14, weight: .medium))
                Text(armado ? T("Soltá para salir", "Release to exit") : T("Mantené apretado para salir", "Press and hold to exit"))
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(progreso > 0.5 ? Color.black : Tema.textoNotch)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 52)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Tema.bordeNotch))
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in apretar() }
            .onEnded { _ in soltar() })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { salir() }
    }

    private func apretar() {
        guard !apretando else { return }
        apretando = true
        withAnimation(.linear(duration: tiempoBoton)) { progreso = 1 }
        let tarea = DispatchWorkItem {
            armado = true
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        armar = tarea
        DispatchQueue.main.asyncAfter(deadline: .now() + tiempoBoton, execute: tarea)
    }

    private func soltar() {
        apretando = false
        armar?.cancel()
        armar = nil
        if armado { salir(); return }
        withAnimation(.easeOut(duration: 0.25)) { progreso = 0 }
    }
}
