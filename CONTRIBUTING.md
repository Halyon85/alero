# Contributing / Colaborar

Thanks for wanting to help. Issues and pull requests are welcome in **English or Spanish**. The code, its comments and
the commit messages are in Spanish (Argentina); new code should follow the same style.

## Before you send a change

1. Build and run the tests (no Xcode needed; they never touch your files, the Trash or real devices):

   ```bash
   swift build -c release && swift test
   ```

2. A fix comes with a test that failed before it.
3. One topic per pull request, with a short description of what changes for the person using the app.

## Ground rules

- Nothing is deleted for good: what Alero removes goes to the Trash.
- A feature that is turned off does nothing in the background (no timers, no listeners).
- Nothing leaves the Mac: no network requests, no analytics.
- Comments say what the code does, who calls it and why.

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE).

---

## Colaborar

Gracias por querer ayudar. Los issues y pull requests pueden ser en **español o en inglés**. El código, los comentarios
y los commits están en español rioplatense; lo nuevo tiene que seguir el mismo estilo.

1. Compilá y corré las pruebas: `swift build -c release && swift test` (no tocan tus archivos, la Papelera ni los aparatos).
2. Un arreglo viene con una prueba que fallaba antes.
3. Un tema por pull request, con una descripción corta de qué cambia para quien usa la app.

Reglas de base: nada se borra para siempre (va a la Papelera); una función apagada no hace nada de fondo; nada sale de
la Mac; los comentarios dicen qué hace el código, quién lo llama y por qué.

Al colaborar aceptás que tu aporte queda bajo la [licencia Apache 2.0](LICENSE).
