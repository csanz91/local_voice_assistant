# Activación local: Okay Nabu

Estado contrastado con el código en **2026-09-19**. El firmware incorpora
`firmware/main/okay_nabu.tflite`, modelo stock de unos 59 KB. La palabra actual
es **«Okay Nabu»**.

- Audio LEFT/comms a 48 kHz, decimado a 16 kHz mediante FIR de 19 taps.
- Input `[1, 3, 40]`; ventana móvil de cinco probabilidades y umbral 0,95.
- Arena TFLite de 40 KB en **PSRAM**, trasladada en `76cd441f` para permitir
  convivencia de TinyUSB y LiveKit sin agotar RAM interna.
- La detección abre una sesión autenticada y entrega el pre-roll. El anillo
  retiene hasta 12 s; el envío está limitado a 2,5 s/80 KB desde `4dc968d4`.
- El pre-roll y el modo dúplex efectivo están documentados en [PROTOCOL](PROTOCOL.md).

Fuentes: [wakeword.zig](../firmware/main/wakeword.zig),
[mww.cpp](../firmware/components/mww/mww.cpp) y
[pre_roll_core.zig](../firmware/main/core/pre_roll_core.zig).

Se conserva el modelo stock y su metadata. Entrenar otro wake word queda fuera
del alcance de la extracción.
