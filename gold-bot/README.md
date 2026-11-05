# GoldGuard — Bot de trading de oro (XAUUSD) para MetaTrader 5 / FxPro

Expert Advisor (`GoldGuard.mq5`) con gestión de riesgo por capas.

> ⚠️ **Aviso honesto:** ningún bot garantiza ganancias. El código no se pudo
> compilar ni probar en este entorno (no hay MetaEditor). **Compílalo, haz
> backtest y opera en DEMO al menos 2–4 semanas antes de usar dinero real.**
> El trading apalancado con oro puede hacerte perder más de lo esperado.

## ¿Funciona en el celular?

El celular **no ejecuta** bots. La app de MT5 (iOS/Android) no permite instalar
Expert Advisors. La forma correcta:

| Pieza | Dónde corre |
|---|---|
| El bot (GoldGuard) | **VPS** con MT5 (MQL5 VPS desde el terminal, o cualquier VPS Windows) |
| Tú, desde el celular | App MT5 de FxPro: ver/cerrar posiciones + **notificaciones push** del bot |

Alternativa: dejar una PC encendida 24/5 (menos fiable que un VPS).

## Instalación (una sola vez, en PC)

1. Abre tu cuenta **FxPro MT5** (demo primero) en el MetaTrader 5 de escritorio.
2. `Archivo → Abrir carpeta de datos → MQL5 → Experts`, copia `GoldGuard.mq5`.
3. Abre MetaEditor (F4), abre el archivo y pulsa **Compilar (F7)**. Debe dar 0 errores.
   Si da errores, pásamelos y los corrijo.
4. Abre un gráfico **XAUUSD** (en FxPro puede llamarse `XAUUSD` o similar), cualquier timeframe.
5. Arrastra GoldGuard al gráfico, pestaña *Común*: activa **Permitir trading algorítmico**.
   Activa el botón **Algo Trading** de la barra superior.
6. Notificaciones al celular: en la app móvil, `Ajustes → Mensajes` copia tu **MetaQuotes ID**;
   en el PC `Herramientas → Opciones → Notificaciones` pégalo y activa push.
7. Para correrlo 24/5: en el terminal clic derecho sobre la cuenta → **Registrarse en VPS**
   (MQL5 VPS) y migra el EA/gráfico.

## Cómo decide entrar

Solo opera si **todas** estas condiciones se cumplen (en velas ya cerradas):

**Compra**
1. Tendencia alcista en H1: EMA50 > EMA200 y el cierre por encima de EMA200.
2. ADX(H1) ≥ 20 (hay tendencia real, no rango).
3. En M15 el precio retrocede y toca la EMA21, y la vela cierra **arriba** de ella siendo alcista.
4. RSI entre 40 y 65 y subiendo (ni sobrecomprado ni sin fuerza).

**Venta:** el espejo exacto.

Entrada a mercado al abrir la siguiente vela. Una evaluación por vela nueva.

## Cómo mide y limita el riesgo (capas)

| Capa | Qué hace | Default |
|---|---|---|
| Riesgo por trade | Lote calculado para que el SL pierda un % fijo del equity | 0.5 % |
| SL siempre presente | SL = 1.5×ATR, TP = 2×SL (R:R 1:2) | — |
| Lote mínimo seguro | Si el lote mínimo arriesga > 1.5× lo planeado, **no opera** | cuenta chica = no opera |
| Posiciones | Máximo abiertas a la vez | 1 |
| Trades/día | Límite diario | 3 |
| Pérdidas seguidas | Pausa el resto del día | 2 |
| Pérdida diaria | Cierra todo y para el día | 2 % |
| Drawdown máximo | Desde el pico de equity: cierra todo y **bloquea** hasta que lo reactives | 8 % |
| Spread | No entra si el spread es alto | 40 pts ($0.40) |
| Volatilidad | No entra en picos de ATR (noticias) ni mercado muerto | 2.5× / 0.6× |
| Horario | Solo 10:00–20:00 hora servidor (Londres + Nueva York) | — |
| Noticias | Ventana sin operar diaria 15:25–15:50 (datos de EE.UU. 8:30 NY) | editable |
| Viernes | Sin entradas 2 h antes y cierra todo a las 20:00 (evita gaps de fin de semana) | on |
| Margen | Exige margen libre ≥ 3× el requerido | 3× |
| Estado persistente | Pico y pérdida diaria sobreviven a reinicios del terminal | — |

Gestión de la posición: break-even al llegar a +1R (asegura 0.1R) y trailing por ATR desde +1.5R.

**Horas del servidor FxPro:** GMT+2 (invierno) / GMT+3 (verano), alineado con el cierre de
Nueva York, así que 15:30 servidor = 8:30 NY todo el año. Para FOMC (14:00 NY = 21:00 servidor)
o eventos puntuales, añade ventanas en `InpNoTradeWindows`, ej: `15:25-15:50;20:30-21:30`.

## Backtest antes de usar

1. MT5 → `Ver → Probador de estrategias` (Ctrl+R).
2. Experto: GoldGuard · Símbolo: XAUUSD · Período: M15 · Modelo: **Cada tick basado en ticks reales**.
3. Prueba ≥ 2 años, depósito igual al tuyo, y compara **drawdown máximo, factor de beneficio y número de trades**.
4. Si el drawdown del test supera el 8 %, baja `InpRiskPercent` (ej. 0.25).
5. Optimiza poco: demasiados parámetros ajustados = sobreajuste (se ve bien en el pasado, falla en vivo).

## Recomendaciones de uso

- Empieza con `InpRiskPercent = 0.25–0.5` y cuenta demo.
- Con cuenta pequeña (< ~$500) el lote mínimo (0.01) puede arriesgar más de lo planeado; el bot lo detecta y no opera. Ajusta con cuidado.
- Revisa que tu cuenta FxPro sea de tipo MT5 (no cTrader); funciona en *netting* y *hedging*.
- Reactivar tras bloqueo por drawdown: pon `InpResetHalt = true`, reinicia el EA, y vuelve a `false`.

## Modo escalera (cuentas muy pequeñas, ej. 10 USD)

`InpLotMode = LOT_LADDER` (por defecto): **0.01 lotes por cada 10 USD de equity**
(`InpLadderStepUSD`, `InpLadderLot`). Con 10–19 USD opera 0.01; con 20 USD, 0.02; etc.
Sube al ganar y baja al perder. Para volver al cálculo por % de riesgo usa `LOT_RISK_PERCENT`.

Con 10 USD, un SL típico de oro (~3–5 USD con 0.01 lote) es ~30–50 % de la cuenta:

- `InpLadderMaxRiskPct` (60 %) impide entrar si el SL perdería más que eso; tras una pérdida
  grande el bot dejará de operar hasta que el saldo se recupere.
- Los límites de pérdida diaria (2 %) y drawdown (8 %) se disparan con **una sola** pérdida.
  Con 10 USD súbelos (p. ej. diaria 50 %, drawdown 70 %) si quieres que siga operando,
  sabiendo que arriesgas la cuenta entera.
- Pide al broker margen suficiente: con poco apalancamiento, 0.01 lote de oro puede no caber en 10 USD.
