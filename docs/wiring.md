# Wiring the ELEGOO kit to the Tang Nano 9K

The Tang Nano 9K's I/O is **3.3 V**. Most of the ELEGOO Mega 2560 kit expects
**5 V** (it's built around the Arduino). Most parts are fine, but a couple can
push 5 V *into* the FPGA and slowly (or quickly) kill a pin. So read this
before plugging stuff in :o

Pin numbers match [`fpga/tangnano9k/tangnano9k.cst`](../fpga/tangnano9k/tangnano9k.cst).
I picked header pins from the 3.3 V banks. **Double-check them against the
pinout printed on your board / Sipeed's pinout diagram** (board revisions
differ) and change the `.cst` if needed.

Power: the kit parts get 5 V from the Tang Nano's `5V` header pin (it comes
straight from USB) and ground from any `GND`. Every part needs a shared GND.

## 1602 LCD (4-bit mode)

| LCD pin | Goes to | Why |
|---------|---------|-----|
| VSS | GND | |
| VDD | 5V | the LCD itself runs at 5 V |
| V0 | middle of the 10k pot (ends to 5V / GND) | contrast. if you see nothing, turn this! |
| RS | FPGA pin 25 | |
| RW | **GND** | we only ever write, so the LCD never drives 5 V back at us |
| E | FPGA pin 26 | |
| D4-D7 | FPGA pins 27, 28, 29, 30 | D0-D3 not connected (4-bit mode) |
| A | 5V through 220 Ω | backlight |
| K | GND | |

3.3 V logic into a 5 V HD44780 is technically under spec (it wants ~0.7 x VDD),
but it works on basically every 1602 module I've seen people try. If
yours shows garbage, power the LCD's VDD from 3.3 V instead (dimmer, but
in spec), or add a 74HC245/level shifter.

## HC-SR04 ultrasonic sensor

| Sensor pin | Goes to |
|------------|---------|
| VCC | 5V |
| TRIG | FPGA pin 33 (3.3 V is enough to trigger it) |
| ECHO | **voltage divider** -> FPGA pin 34 |
| GND | GND |

**ECHO outputs 5 V.** Use two resistors from the kit:
```
ECHO ---[ 1k ]---+--- FPGA pin 34
                 |
               [ 2k ]   (or 2 x 1k in series)
                 |
                GND
```
That gives 5 V x 2k / 3k ≈ 3.3 V.

## Passive buzzer

| Buzzer | Goes to |
|--------|---------|
| + | FPGA pin 35 (through ~100 Ω) |
| - | GND |

Louder: drive it through the kit's PN2222 / S8050 NPN transistor (FPGA pin -> 1k -> base,
emitter -> GND, buzzer between 5V and collector).

## 4-digit 7-segment (5461AS, common cathode)

| Display | Goes to |
|---------|---------|
| segments a, b, c, d, e, f, g, dp | FPGA pins 48, 49, 53, 54, 55, 56, 57, 68 - each through a 220 Ω resistor |
| digit 1 (leftmost) ... digit 4 | FPGA pins 72, 71, 70, 69 (`dig[3]` ... `dig[0]`) |

The digit pins sink a whole digit's current. It works straight off the FPGA
but it's a bit dim. For full brightness, put each digit pin through an NPN
(and set `ACTIVE_LOW_DIGITS` to 0 in `sevenseg.sv`, since the transistor
inverts it).

## Buttons

| Button | Goes to |
|--------|---------|
| onboard S1 | reset |
| onboard S2 | button 0 |
| kit button 1-3 | FPGA pins 40, 41, 42, other leg to **GND** (internal pull-ups, no resistor needed) |

## What about the Arduino Mega itself?

The Mega can't run Verilog (it's a microcontroller, not an FPGA), so it
doesn't run purr-V. Ideas for still using it:
- a **logic probe / serial monitor**: its 5 V inputs read 3.3 V signals fine,
  so it can watch pins and print them
- run the original [arduino-parking-sensor](https://github.com/raffytaffy627/arduino-parking-sensor)
  side by side with the purr-V port and compare :p
- don't wire any Mega **output** straight into the FPGA (5 V!) without a divider
