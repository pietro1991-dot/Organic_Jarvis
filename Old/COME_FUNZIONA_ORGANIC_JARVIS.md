# 🌱 Come Funziona EA Organic Jarvis v1.1
## Guida al Sistema 100% Data-Driven basato sull'Esponente di Hurst

> Nota: questa guida nella cartella `Old/` e' una spiegazione concettuale storica.
> Per le modifiche piu recenti della v1.1 (Soft Hurst / TF coherence / circuit breaker / doppio export CSV con file `trades_ext_...`), fai riferimento a `DOC_ORGANIC_JARVIS_v1.1_ULTRA_DETTAGLIATA.md` nella root.

---

## 🎯 IL CUORE DEL SISTEMA: L'Esponente di Hurst (H)

L'**Esponente di Hurst** è un numero calcolato dai dati di mercato che misura la "memoria" del prezzo:

```
H > centro → TRENDING (i movimenti continuano nella stessa direzione)
H = centro → RANDOM WALK (movimenti casuali, imprevedibili)
H < centro → MEAN-REVERTING (i movimenti tendono a invertirsi)
```

### Da H deriviamo TUTTO:

| Funzione | Formula | Significato |
|----------|---------|-------------|
| **scale(H)** | 2^H | Fattore di scala (~1.4 per H=0.5, ~1.6 per H=0.7) |
| **decay(H)** | 2^(-H) | Fattore di smorzamento (~0.7 per H=0.5, ~0.6 per H=0.7) |
| **decay²(H)** | 2^(-2H) | Smorzamento quadratico (~0.25 per H=0.5) |

**NESSUNA COSTANTE ARBITRARIA** - Tutto deriva da 2^H calcolato sui dati reali!

---

## 🧱 ARCHITETTURA DEL SISTEMA

```
┌─────────────────────────────────────────────────────────────────────┐
│                    DATI DI MERCATO (OHLCV)                          │
│                           │                                          │
│      ┌────────────────────┴────────────────────┐                    │
│      ▼                                         ▼                    │
│  CALCOLO HURST                          PRE-CARICAMENTO             │
│  (autocorrelazione)                     (storia → buffer)           │
│      │                                         │                    │
│      ▼                                         ▼                    │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                 BUFFER DATA-DRIVEN                           │   │
│  │  • g_hurstHistory[] → Centro, Stdev, Zona                   │   │
│  │  • g_tradeScoreHistory[] → Punteggi storici                 │   │
│  │  • g_scoreHistory[] → Score per soglia dinamica             │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                           │                                          │
│                           ▼                                          │
│              PARAMETRI 100% DERIVATI DA H                           │
│              (scale, decay, periodi, pesi, soglie)                  │
│                           │                                          │
│                           ▼                                          │
│                    SEGNALE DI TRADING                               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 1️⃣ PRE-CARICAMENTO: L'EA Parte Subito!

### Cosa Succede in OnInit():

```
1. PreloadHurstBufferFromHistory()
   │
   ├── Carica barre storiche da M5, H1, H4, D1
   │
   ├── Calcola Hurst composito per ogni campione storico
   │
   ├── Riempie g_hurstHistory[] (buffer circolare)
   │
   ├── Calcola Centro e Stdev Hurst empirici
   │   g_hurstCenter = mean(buffer)
   │   g_hurstStdev = stdev(buffer)
   │
   ├── Calcola Zona Random adattiva
   │   g_hurstRandomLow = centro - stdev × decay(H)
   │   g_hurstRandomHigh = centro + stdev × decay(H)
   │
   └── Calcola TradeScore per ogni campione
       → Riempie g_tradeScoreHistory[]
```

### Risultato:
**L'EA è PRONTO per il trading appena parte** - non deve aspettare ore per raccogliere dati!

---

## 2️⃣ PERIODO NATURALE: Il Battito del Mercato

Ogni mercato ha un suo "ritmo" naturale che emerge dall'**autocorrelazione**:

```
Calcola autocorrelazione per lag = 1, 2, 3, ...
Quando autocorr < decay(H) → quello è il periodo naturale!

Esempio:
  lag=10: autocorr = 0.72 (ancora alto)
  lag=15: autocorr = 0.58 (ancora sopra soglia 0.62)
  lag=18: autocorr = 0.51 (sotto soglia!) → PERIODO = 18
```

### Tutti gli Indicatori Derivano dal Periodo:

| Indicatore | Formula | Esempio (periodo=18, H=0.6) |
|------------|---------|----------------------------|
| EMA | periodo × scale(H) | 18 × 1.52 = 27 |
| RSI | periodo × scale(H) | 27 |
| MACD Fast | periodo | 18 |
| MACD Slow | periodo × scale²(H) | 18 × 2.3 = 41 |
| ATR | periodo × scale²(H) | 41 |
| Bollinger | periodo × scale²(H) | 41 |

---

## 3️⃣ PESI TIMEFRAME: Chi Conta di Più?

### Calcolo Data-Driven:

```
peso_TF = H_TF / Σ(H_tutti_TF)

Esempio:
  H(M5) = 0.55  →  peso = 0.55/2.23 = 25%
  H(H1) = 0.62  →  peso = 0.62/2.23 = 28%  ← Più affidabile!
  H(H4) = 0.48  →  peso = 0.48/2.23 = 21%  ← Meno affidabile
  H(D1) = 0.58  →  peso = 0.58/2.23 = 26%
```

**Il timeframe con Hurst più alto** (più trending) conta di più!

---

## 4️⃣ CENTRI EMPIRICI: Niente Più 50, 70, 30!

### Il Centro Adattivo cambia con il regime di mercato:

```
H >= centro + margine    → Centro = EMA (segue il trend)
H ≈ centro               → Centro = Mediana (robusto)
H <= centro - margine    → Centro = Trimmed Mean (ignora outlier)
```

Dove `centro` e `margine` sono calcolati dalla distribuzione storica di H!

### Esempio RSI:

```
Mercato TRENDING (H=0.65):
  Centro RSI = EMA(RSI ultimi N) = 58
  → RSI=65 è solo +7 punti sopra centro
  → Voto = +0.35 (compra moderato)

Mercato MEAN-REVERTING (H=0.38):  
  Centro RSI = TrimmedMean(RSI ultimi N) = 47
  → RSI=65 è +18 punti sopra centro
  → Voto = +0.90 (compra forte, aspetta inversione)
```

---

## 5️⃣ SCALE EMPIRICHE: Tutto dai Dati

### RSI Scale:
```
rsi_scale = stdev(RSI) × scale(H)
```

### OBV Scale:
```
obv_scale = stdev(variazioni OBV) × scale(H)

Fallback se stdev ≈ 0:
obv_scale = range(OBV) / (scale² × √n)
```

### ATR Scale:
```
atr_scale = ATR_medio × scale(H)

Fallback:
min_scale = point_value × periodo_naturale × scale(H)
```

**MAI divisione per zero** - fallback multipli garantiscono valori validi!

---

## 6️⃣ SOGLIE DINAMICHE: Otsu → Youden

### Fase 1: Otsu (Warm-up)
Trova la soglia che **separa** meglio gli score alti da quelli bassi:

```
soglia_otsu = argmax(varianza_tra_gruppi / varianza_totale)
```

### Fase 2: Youden (Con feedback reali)
Dopo N trade con risultati, ottimizza la soglia per **massimizzare profitti**:

```
J = TPR + TNR - 1

Dove:
  TPR = True Positive Rate (trade buoni sopra soglia)
  TNR = True Negative Rate (trade cattivi sotto soglia)
  
soglia_youden = argmax(J)
```

### Bounds Data-Driven:

```
Floor = percentile decay²(H) della distribuzione score (~25%)
Ceiling = percentile (1-decay²(H)) della distribuzione score (~75%)
```

---

## 7️⃣ FILTRO HURST: Quando NON Tradare

### Zona Random Adattiva:

```
zona_random = [centro - margine, centro + margine]

Dove:
  centro = media storica di H per QUESTO cross
  margine = stdev(H) × decay(H)
```

### Decisione:

```
Se H_attuale è nella zona_random → BLOCCA I TRADE
Se H_attuale > zona_random       → TREND MODE (trade direzionali)
Se H_attuale < zona_random       → REVERSAL MODE (trade contrarian)
```

```
    H basso        Centro         H alto
        │              │              │
    ────┼──────────────┼──────────────┼────
        │   REVERTING  │    RANDOM    │   TRENDING
        │   (trade ok) │  (NO TRADE!) │   (trade ok)
        │              │              │
                    [zona adattiva]
```

---

## 8️⃣ AGGIORNAMENTO CONTINUO

### Ad Ogni Nuova Barra:

```
1. RecalculateOrganicSystem()
   │
   ├── Ricalcola Hurst per ogni TF
   │
   ├── Aggiorna pesi TF
   │
   ├── Ricalcola periodi organici (se cambio > 25%)
   │
   ├── AddHurstToHistory(H_nuovo)
   │   └── Aggiorna centro, stdev, zona
   │
   └── AddScoreToHistory(score_nuovo)
       └── Aggiorna soglia dinamica
```

### Anti-Drift Numerico:
Ogni SCORE_HISTORY_MAX operazioni, ricalcola le somme da zero per evitare errori floating point accumulati.

---

## 📊 RIEPILOGO: Da Dove Viene Ogni Parametro

| Parametro | Fonte | Formula |
|-----------|-------|---------|
| Periodo naturale | Autocorrelazione | lag dove autocorr < decay(H) |
| Periodi indicatori | Periodo naturale | × scale(H), × scale²(H) |
| Pesi TF | Hurst per TF | H_TF / Σ(H) |
| Centro RSI | Dati RSI | EMA/Mediana/Trimmed (dipende da H) |
| Scala RSI | Stdev RSI | stdev × scale(H) |
| Zona Hurst | Distribuzione H | centro ± stdev × decay(H) |
| Soglia score | Distribuzione score | Otsu o Youden |
| minSamples | Buffer size | buffer × decay²(H) |
| Clamp soglie | Hurst | [decay², decay] |
| Warmup barre | Periodo naturale | max(64, periodo × scale) |

---

## 🔬 PERIODI NATURALI DI DEFAULT (Non Arbitrari!)

Le dimensioni dei buffer sono derivate dalla **struttura temporale del mercato**:

| Periodo Default | Valore | Derivazione |
|-----------------|--------|-------------|
| DEFAULT_PERIOD_M5 | 12 | 1 ora di trading (12 × 5min = 60min) |
| DEFAULT_PERIOD_H1 | 24 | 1 giorno (24 ore) |
| DEFAULT_PERIOD_H4 | 6 | 1 giorno (6 × 4h = 24h) |
| DEFAULT_PERIOD_D1 | 5 | 1 settimana lavorativa (5 giorni) |

### Buffer Size Data-Driven:

```
GetBufferSmall()  = DEFAULT_PERIOD_M5 × scale⁰(H)  ≈ 12
GetBufferMedium() = DEFAULT_PERIOD_M5 × scale¹(H)  ≈ 17 per H=0.5
GetBufferLarge()  = DEFAULT_PERIOD_H1 × scale¹(H)  ≈ 34 per H=0.5
GetBufferXLarge() = DEFAULT_PERIOD_H1 × scale²(H)  ≈ 48 per H=0.5
GetBufferHuge()   = DEFAULT_PERIOD_H1 × scale³(H)  ≈ 68 per H=0.5
```

Le uniche costanti fisse:

| Nome | Valore | Perché |
|------|--------|--------|
| HURST_DEFAULT | 0.5 | Random walk teorico (fallback iniziale) |
| HURST_RANGE | [0.1, 0.9] | Limiti fisici sensati |

**TUTTO IL RESTO** deriva da Hurst e dai dati di mercato!

---

## 🎯 VANTAGGI DEL SISTEMA DATA-DRIVEN

1. **Adattività**: Si adatta automaticamente a ogni mercato
2. **No Overfitting**: Nessun parametro ottimizzato su dati passati
3. **Coerenza Matematica**: Tutto deriva da una sola fonte (H)
4. **Robustezza**: Fallback multipli garantiscono sempre valori validi
5. **Trasparenza**: Ogni parametro ha una derivazione chiara
6. **Zero Magic Numbers**: Nessun 14, 21, 50, 70, ecc.

---

## 📈 FLUSSO COMPLETO: Dal Prezzo al Trade

```
PREZZI STORICI
      │
      ▼
PRE-CARICAMENTO (OnInit)
      │
      ├── Buffer Hurst ────────► Centro, Stdev, Zona
      │
      └── Buffer TradeScore ───► Prontezza al trading
      │
      ▼
NUOVA BARRA (OnTick)
      │
      ├── Calcola H per ogni TF
      │
      ├── Aggiorna Pesi TF
      │
      ├── Calcola Centri Adattivi
      │
      ├── Calcola Score Indicatori
      │
      ├── Somma Score × Peso TF
      │
      ├── Confronta con Soglia Dinamica
      │
      └── DECISIONE: BUY / SELL / HOLD
```

---

## 🔄 FORMULE CHIAVE

### Funzioni Base da Hurst:
```
scale(H) = 2^H              // ~1.41 per H=0.5, ~1.62 per H=0.7
decay(H) = 2^(-H)           // ~0.71 per H=0.5, ~0.62 per H=0.7
decay²(H) = 2^(-2H)         // ~0.50 per H=0.5, ~0.38 per H=0.7
```

### Zona Hurst:
```
centro = mean(H_storici)
margine = stdev(H_storici) × decay(H)
zona = [centro - margine, centro + margine]
```

### Peso Timeframe:
```
peso_TF = H_TF / Σ(H_tutti_TF)
```

### Centro Adattivo:
```
Se H > centro + margine/2:  centro = EMA(dati)
Se H ≈ centro:              centro = Mediana(dati)
Se H < centro - margine/2:  centro = TrimmedMean(dati)
```

### Score Normalizzato:
```
voto = (valore - centro) / scala
scala = stdev × scale(H)
```

### Soglia Dinamica:
```
warmup:  soglia = Otsu(distribuzione score)
mature:  soglia = Youden(score + profitti)
bounds:  [decay²(H), 1-decay²(H)] della distribuzione
```

---

*Documentazione v1.1 - Sistema 100% Data-Driven basato su 2^H*
*Ultimo aggiornamento: Gennaio 2026*
