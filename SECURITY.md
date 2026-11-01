# Security / Seguridad

Alero sends files and apps to the Trash, runs commands you type in its terminal, listens to keyboard and mouse events
and can install a narrow administrator rule for *Coffee with the lid closed*. A bug in any of those can cost someone
their data or their privacy, so security reports get priority.

## Reporting a vulnerability

**Please do not open a public issue.** Use GitHub's private reporting instead: the **Security** tab of this repository →
**Report a vulnerability**. Include what you did, what happened and, if you can, a way to reproduce it.

We will confirm we received it within a few days, tell you what we plan to do and credit you in the fix if you want.

## What counts

- Anything that makes Alero move or delete something outside what you chose (for example, a crafted app bundle in
  the uninstaller).
- Keystrokes or mouse events leaking, or being acted on when the matching feature is off.
- Using the *Coffee with the lid closed* rule for anything other than its two `pmset` commands.

Only the latest version is supported.

---

## Avisar un problema de seguridad

**No abras un issue público.** Usá el aviso privado de GitHub: pestaña **Security** de este repositorio → **Report a
vulnerability**. Contá qué hiciste, qué pasó y, si podés, cómo repetirlo. Te confirmamos que lo recibimos en unos días,
te contamos qué vamos a hacer y, si querés, te damos el crédito en el arreglo.
