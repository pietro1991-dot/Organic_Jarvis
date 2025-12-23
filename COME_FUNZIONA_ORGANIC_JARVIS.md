# 🌱 Come Funziona EA Organic Jarvis
## Guida Semplice al Sistema 100% Autocalcolato

---

## 🌻 IL NUMERO MAGICO DELLA NATURA: φ (Phi)

Prima di tutto, parliamo del **numero speciale** che tiene tutto insieme: **φ (Phi, il Rapporto Aureo)**.

### Cos'è φ?

Immagina di avere una linea:
```
|─────────────────────────────────|
A                                 B
```

Ora la dividi in due parti così che:
- La parte GRANDE sta alla parte PICCOLA
- Come la linea INTERA sta alla parte GRANDE

```
|────────────────────|────────────|
A         GRANDE     C   PICCOLA  B

   GRANDE       TUTTO
   ───────  =  ───────  =  φ ≈ 1.618
   PICCOLA      GRANDE
```

Questo numero (≈ 1.618) è **φ** - e la natura lo usa OVUNQUE!

### Dove si trova φ in natura?

```
    🌻 GIRASOLE              🐚 CONCHIGLIA           🌀 GALASSIA
    
    I semi seguono          La spirale cresce       Le braccia seguono
    la spirale φ            di φ ogni giro          curve basate su φ

    🌿 FOGLIE                👤 CORPO UMANO          🌲 ALBERI
    
    Crescono a 137.5°       Ombelico divide         I rami si dividono
    (360°/φ²)               il corpo in φ           secondo φ
```

### Perché usiamo φ nel trading?

Perché **se la natura usa questo numero per crescere in modo armonioso, forse anche il mercato (fatto di esseri umani, che sono natura) segue questi ritmi!**

Invece di inventare numeri a caso (14 per RSI, 50 per media...), usiamo SOLO φ e le sue potenze.

---

## 🎯 L'Idea in 30 Secondi

Immagina di voler sapere se domani pioverà. 

**Metodo tradizionale:** "Se la pressione è sotto 1013 hPa, piove" ← numero fisso, uguale ovunque

**Metodo organico:** "Guardo la pressione degli ultimi 100 giorni QUI, calcolo la media e dico: se oggi è sotto la media, probabilmente piove" ← adattato al luogo

L'EA Organic Jarvis fa esattamente questo: **non usa numeri fissi, ma calcola tutto dai dati del mercato che sta tradando**.

---

## 🧱 I 4 Mattoncini del Sistema

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   1️⃣ PERIODO NATURALE                                          │
│   ↓                                                             │
│   2️⃣ PERIODI INDICATORI (EMA, RSI, MACD...)                    │
│   ↓                                                             │
│   3️⃣ PESI TIMEFRAME (chi conta di più?)                        │
│   ↓                                                             │
│   4️⃣ VOTO FINALE (compro o vendo?)                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1️⃣ PERIODO NATURALE: Il Battito del Mercato

### Cos'è?
Ogni mercato ha un suo "ritmo". L'EUR/USD potrebbe avere cicli di 15 barre, il Gold di 25 barre. Non è uguale per tutti!

### Come lo calcola?
Usa l'**autocorrelazione**: quanto il prezzo di oggi somiglia a quello di N barre fa?

```
Barra 1: 1.1000
Barra 2: 1.1010
Barra 3: 1.1005
...
Barra 15: 1.1008  ← Somiglia molto a barra 1!

→ Il mercato "ricorda" per circa 15 barre
→ Periodo naturale = 15
```

### Formula semplificata:
```
Per ogni lag (1, 2, 3, 4...):
    Calcola quanto il prezzo è simile a N barre fa
    Quando la somiglianza scende sotto 38.2% (= 1/φ²)
    → Quello è il periodo naturale!
```

### Perché 38.2%?
È **1 diviso φ al quadrato** (φ = 1.618, il rapporto aureo). Usiamo solo questo numero speciale per tutte le scale.

---

## 2️⃣ PERIODI INDICATORI: Tutto Deriva dal Periodo Naturale

Una volta trovato il periodo naturale, **tutti gli indicatori usano periodi derivati da esso**.

### Esempio con periodo naturale = 15:

| Indicatore | Formula | Risultato |
|------------|---------|-----------|
| EMA | periodo × φ | 15 × 1.618 = 24 |
| RSI | periodo × φ | 24 |
| MACD Fast | periodo | 15 |
| MACD Slow | periodo × φ² | 15 × 2.618 = 39 |
| ATR | periodo × φ² | 39 |
| Bollinger | periodo × φ² | 39 |

### Visualizzazione:
```
                    Periodo Naturale = 15
                           │
           ┌───────────────┼───────────────┐
           │               │               │
        × 1/φ             × 1             × φ
        (veloce)       (medio)         (lento)
           │               │               │
           9              15              24
           │               │               │
        Stoch D        MACD Fast         EMA
        Slowing                          RSI
```

---

## 3️⃣ PESI TIMEFRAME: Chi Conta di Più?

### Il Problema
Abbiamo 4 timeframe: M5, H1, H4, D1. Se M5 dice "compra" e D1 dice "vendi", chi ha ragione?

### La Soluzione: Esponente di Hurst
### L'Esponente di Hurst (H) misura se il mercato sta **trendando** o **oscillando**:

```
H > centro storico → Il mercato sta TRENDANDO (i movimenti continuano)
H = centro storico → Il mercato è nella ZONA RANDOM (movimenti casuali)
H < centro storico → Il mercato sta OSCILLANDO (i movimenti si invertono)
```

**Nota:** Il "centro" è la media storica di H per quel cross, NON 0.5 teorico!

### Come Calcola i Pesi?

```
Esempio:
  H di M5 = 0.55 (leggero trend)
  H di H1 = 0.62 (trend forte)
  H di H4 = 0.48 (oscillazione)
  H di D1 = 0.58 (trend)
  
Somma = 0.55 + 0.62 + 0.48 + 0.58 = 2.23

Peso M5 = 0.55 / 2.23 = 25%
Peso H1 = 0.62 / 2.23 = 28%  ← Conta di più!
Peso H4 = 0.48 / 2.23 = 21%  ← Conta meno
Peso D1 = 0.58 / 2.23 = 26%
```

### Perché Funziona?
- Se H1 è in **forte trend**, il suo segnale è più affidabile → peso maggiore
- Se H4 sta **oscillando**, i segnali sono rumore → peso minore

---

## 4️⃣ VOTO FINALE: Come Decide se Comprare

### Step 1: Ogni Indicatore Vota (per ogni TF separatamente!)

Ogni indicatore dà un voto da **-1** (vendi forte) a **+1** (compra forte).
Il voto usa il **centro empirico del SUO timeframe**:

```
Esempio M5 (usa centri calcolati su M5):
  RSI M5 = 58, centro_M5 = 48, scala_M5 = 19
  Voto RSI = (58 - 48) / 19 = +0.53 (compra moderato)

Esempio H1 (usa centri calcolati su H1):
  RSI H1 = 55, centro_H1 = 52, scala_H1 = 15
  Voto RSI = (55 - 52) / 15 = +0.20 (compra debole)
```

### Step 2: Somma i Voti del TF × Peso TF

```
Score M5 = (voto_EMA + voto_RSI + voto_MACD + ...) × Peso_M5
Score H1 = (voto_EMA + voto_RSI + voto_MACD + ...) × Peso_H1
Score H4 = (voto_EMA + voto_RSI + voto_MACD + ...) × Peso_H4
Score D1 = (voto_EMA + voto_RSI + voto_MACD + ...) × Peso_D1
```

**NOTA:** Il peso è già moltiplicato dentro `CalculateSignalScore()`!

### Step 3: Somma Tutti i TF

```
Score Totale = Score_M5 + Score_H1 + Score_H4 + Score_D1

Esempio:
  Score M5 = +2.5 × 0.25 = +0.625
  Score H1 = +3.2 × 0.28 = +0.896
  Score H4 = -1.0 × 0.21 = -0.210
  Score D1 = +2.0 × 0.26 = +0.520
  
  TOTALE = +1.831
```

### Step 4: Confronta con la Soglia

La soglia è **calcolata dai dati storici**, non fissa!

```
Soglia = Media(score passati) + DevStd × 0.618

Esempio: Soglia = 1.2

Score 1.831 > Soglia 1.2 → ✅ COMPRA!
```

---

## 🔄 Il Filtro Hurst: Quando NON Tradare

### ⚠️ IMPORTANTE: Ogni Timeframe ha i SUOI Centri!

I centri empirici sono calcolati **separatamente per ogni timeframe**:

```
M5:  rsi_center = media(RSI su M5)    → 48.2
H1:  rsi_center = media(RSI su H1)    → 51.7
H4:  rsi_center = media(RSI su H4)    → 49.3
D1:  rsi_center = media(RSI su D1)    → 52.1
```

Questo perché lo stesso indicatore si comporta diversamente su timeframe diversi!

### Flusso Completo Multi-Timeframe:

```
1. CARICA DATI per ogni TF (separatamente)
        ↓
2. CALCOLA CENTRI EMPIRICI per ogni TF (separatamente)
   tfData_M5.rsi_center = media(RSI su barre M5)
   tfData_H1.rsi_center = media(RSI su barre H1)
   ...
        ↓
3. CALCOLA SCORE per ogni TF (usando i SUOI centri)
   scoreM5 = Σ[(indicatore - centro_M5) / scala_M5] × peso_M5
   scoreH1 = Σ[(indicatore - centro_H1) / scala_H1] × peso_H1
   ...
        ↓
4. SOMMA GLI SCORE di tutti i TF
   totalScore = scoreM5 + scoreH1 + scoreH4 + scoreD1
        ↓
5. CONFRONTA con soglia dinamica
```

### Il Problema
Se il mercato è vicino al suo **centro storico** di Hurst, i segnali sono rumore. Meglio stare fermi!

### ⚠️ IMPORTANTE: Il Centro NON è 0.5!

Il famoso "0.5 = random walk" è un valore **teorico**. Ma ogni mercato ha il suo centro reale!

```
Esempio:
  EUR/USD storicamente ha H medio = 0.52
  Gold storicamente ha H medio = 0.48
  Bitcoin storicamente ha H medio = 0.56

Ogni mercato è diverso! Usiamo il SUO centro, non 0.5 teorico.
```

### Come Funziona

```
1. Calcola la media storica di H per QUESTO cross (es: 0.52)
   g_hurstCenter = Σ(H) / numero_campioni

2. Calcola la deviazione standard (es: 0.08)
   g_hurstStdev = √(Var(H))

3. Zona "random" = centro ± devstd × φ⁻¹
   Zona random = [0.52 - 0.05, 0.52 + 0.05] = [0.47, 0.57]

4. Se H attuale è nella zona random → BLOCCA I TRADE
```

### Prima di Avere Dati?

L'EA **NON entra a mercato** finché non ha abbastanza dati per calcolare il centro empirico!

```
g_hurstReady = false  →  IsTradeAllowedByHurst() = false  →  NO TRADE
```

Questo garantisce che **ogni decisione sia basata su dati reali**, mai su valori teorici.

### Visualizzazione:
```
    H = 0.3        H = 0.5        H = 0.7
        │              │              │
    ────┼──────────────┼──────────────┼────
        │   OSCILLA    │    RANDOM    │   TREND
        │   (trade ok) │ (NO TRADE!)  │   (trade ok)
        │              │              │
                    [0.47───0.57]
                    zona bloccata
```

---

## 🎯 I Centri Empirici: Niente Più 50, 70, 30!

### Il Problema Classico
RSI > 70 = ipercomprato? Ma forse per Bitcoin la media è 60, quindi 70 è normale!

### La Soluzione
Calcoliamo il **centro reale** per ogni indicatore:

```
Esempio RSI su EUR/USD:
  Ultime 200 barre: media RSI = 48, deviazione = 12
  
  Centro = 48 (non 50!)
  Scala = 12 × 1.618 = 19.4
  
  RSI attuale = 65
  Distanza dal centro = (65 - 48) / 19.4 = +0.88
  
  → Voto = +0.88 (compra moderato)
```

### Tutti gli Indicatori Usano Centri Empirici:

| Indicatore | Centro Tradizionale | Centro Organico |
|------------|---------------------|-----------------|
| RSI | 50 | media(RSI ultime N barre) |
| CCI | 0 | media(CCI ultime N barre) |
| Stochastic | 50 | media(K-D ultime N barre) |
| WPR | -50 | media(WPR ultime N barre) |
| MFI | 50 | media(MFI ultime N barre) |
| Momentum | 100 | media(Mom ultime N barre) |
| AO | 0 | media(AO ultime N barre) |

---

## 📊 Schema Completo: Dal Prezzo al Trade

```
                         PREZZI DI MERCATO (OHLCV)
                                  │
                ┌─────────────────┴─────────────────┐
                │                                   │
                ▼                                   ▼
        AUTOCORRELAZIONE                     METODO R/S
                │                                   │
                ▼                                   ▼
        PERIODO NATURALE                    ESPONENTE HURST
        (es: 15 barre)                      (es: 0.58)
                │                                   │
                ▼                                   │
        PERIODI INDICATORI                          │
        EMA=24, RSI=24, MACD=15/39...               │
                │                                   │
                ▼                                   ▼
        VALORI INDICATORI                   PESI TIMEFRAME
        EMA=1.1050, RSI=58...               M5=25%, H1=28%...
                │                                   │
                ▼                                   │
        CONFRONTO CON                               │
        CENTRI EMPIRICI                             │
        RSI 58 vs centro 48                         │
                │                                   │
                ▼                                   │
        VOTO INDICATORE                             │
        RSI = +0.51                                 │
                │                                   │
                └───────────────┬───────────────────┘
                                │
                                ▼
                    VOTO TF = Σ(voti) × peso
                                │
                                ▼
                    VOTO TOTALE = Σ(voti TF)
                                │
                                ▼
                    CONFRONTO CON SOGLIA
                    (soglia = mean + std × φ⁻¹)
                                │
                        ┌───────┴───────┐
                        │               │
                        ▼               ▼
                    SOPRA           SOTTO
                    SOGLIA          SOGLIA
                        │               │
                        ▼               ▼
                FILTRO HURST?      NO TRADE
                        │
                ┌───────┴───────┐
                │               │
            PERMESSO        BLOCCATO
            (H fuori       (H in zona
            zona random)    random)
                │               │
                ▼               ▼
        APRI TRADE!        ASPETTA
```

---

## 🔢 L'Unico Numero "Magico": φ (Phi)

Tutto il sistema usa UN SOLO numero speciale: **φ = 1.618** (rapporto aureo)

### Perché φ?
- È ovunque in natura (conchiglie, fiori, galassie)
- Crea proporzioni armoniose
- Non è arbitrario come "14" o "70"

### La Famiglia di φ (potenze e inversi)

φ ha una "famiglia" di numeri tutti collegati tra loro:

```
                              φ = 1.618
                                  │
        ┌─────────────┬───────────┼───────────┬─────────────┐
        │             │           │           │             │
      1/φ³          1/φ²        1/φ          φ            φ²
     ≈ 0.236       ≈ 0.382     ≈ 0.618    ≈ 1.618      ≈ 2.618
        │             │           │           │             │
   (molto piccolo) (piccolo)  (medio)    (grande)   (molto grande)
```

### La Magia: Ogni Membro della Famiglia è Collegato!

```
φ × φ = φ²           (1.618 × 1.618 = 2.618)
φ - 1 = 1/φ          (1.618 - 1 = 0.618)
1/φ + 1/φ² = 1       (0.618 + 0.382 = 1.000)
φ² - φ = 1           (2.618 - 1.618 = 1.000)
```

### Come Usiamo Ogni Membro della Famiglia:

| Chi | Valore | Dove lo Usiamo |
|-----|--------|----------------|
| 1/φ³ | 0.236 | Range Hurst minimo, margini stretti |
| 1/φ² | 0.382 | Soglia autocorrelazione, scala veloce |
| 1/φ | 0.618 | Margini zone, moltiplicatore scale, soglie |
| 1 | 1.000 | Periodo naturale (base) |
| φ | 1.618 | Periodi lenti, scale normali |
| φ² | 2.618 | Periodi molto lenti, buffer grandi |
| φ³ | 4.236 | Periodi lunghissimi |
| ... | ... | ... |
| φ⁹ | 76 | Dimensione buffer trade score |
| φ¹⁰ | 123 | Dimensione buffer Hurst |
| φ¹² | 322 | Dimensione buffer score storia |

---

## 🔗 COME φ COLLEGA TUTTO (LA CATENA AUREA)

Ecco il segreto: **ogni elemento del sistema è collegato agli altri tramite φ!**

### La Catena Aurea Visiva:

```
                     📊 PREZZI DI MERCATO
                            │
                            │ (analisi)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                   AUTOCORRELAZIONE                          │
│                                                             │
│   "Quando la somiglianza scende sotto 1/φ² = 38.2%,        │
│    il mercato ha 'dimenticato' - quello è il PERIODO"      │
│                                                             │
│              Soglia = 1/φ² ← (deriva da φ!)                │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
                    PERIODO NATURALE = N
                    (es: N = 15 barre)
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ▼                   ▼                   ▼
    N × 1/φ             N × 1               N × φ
    = 15 × 0.618        = 15                = 15 × 1.618
    = 9 (veloce)        = 15 (medio)        = 24 (lento)
        │                   │                   │
        ▼                   ▼                   ▼
    Stoch D             MACD Fast            EMA, RSI
    Slowing             Momentum             CCI
                            │
                            ▼
                    VALORI INDICATORI
                    (RSI=58, EMA=1.1050...)
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│               NORMALIZZAZIONE (φ scala tutto)               │
│                                                             │
│   Scala = deviazione_standard × φ                          │
│   Voto = (valore - centro) / scala                         │
│                                                             │
│         ↑ usa φ!          ↑ calcolato dai dati!            │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
                    VOTO INDICATORE
                    (es: +0.53)
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                  PESATURA TIMEFRAME                         │
│                                                             │
│   Peso = Hurst_TF / Σ(Hurst)                               │
│   Score = Σ(voti) × peso                                   │
│                                                             │
│         ↑ Hurst calcolato con scale φⁿ!                    │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
                    SCORE TOTALE
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                   CONFRONTO SOGLIA                          │
│                                                             │
│   Soglia = media_storica + deviazione × 1/φ                │
│                                          ↑ usa φ!          │
└──────────────────────────────────────────────────────────────┘
                            │
                ┌───────────┴───────────┐
                │                       │
            SOPRA                   SOTTO
                │                       │
                ▼                       ▼
┌───────────────────────────┐   ┌───────────────────────────┐
│     FILTRO HURST          │   │                           │
│                           │   │       NO TRADE            │
│ Zona random = centro      │   │                           │
│              ± stdev × 1/φ│   └───────────────────────────┘
│                      ↑    │
│                   usa φ!  │
│                           │
│ Range valido:             │
│ [1/φ³, 1-1/φ³]           │
│ = [0.236, 0.764]          │
│    ↑         ↑            │
│  usa φ!    usa φ!         │
└───────────────────────────┘
                │
        ┌───────┴───────┐
        │               │
    FUORI ZONA      IN ZONA
        │               │
        ▼               ▼
    🟢 TRADE!       ⏸️ ASPETTA
```

### Riassunto: TUTTO Deriva da φ!

| Elemento | Formula | φ coinvolto? |
|----------|---------|--------------|
| Soglia autocorrelazione | 1/φ² | ✅ |
| Periodi veloci | naturale × 1/φ | ✅ |
| Periodi lenti | naturale × φ | ✅ |
| Periodi molto lenti | naturale × φ² | ✅ |
| Scale indicatori | stdev × φ | ✅ |
| Soglia score | media + stdev × 1/φ | ✅ |
| Zona random Hurst | centro ± stdev × 1/φ | ✅ |
| Range Hurst valido | [1/φ³, 1-1/φ³] | ✅ |
| Dimensione buffer Hurst | φ¹⁰ ≈ 123 | ✅ |
| Dimensione buffer score | φ¹² ≈ 322 | ✅ |
| Minimi barre analisi | φ⁴ ≈ 7 | ✅ |
| Scale Hurst R/S | φ⁵, φ⁶, φ⁷, φ⁸, φ⁹ | ✅ |

**È come un albero dove tutte le foglie sono collegate ai rami, i rami al tronco, e il tronco alla radice - che è φ!**

---

## ✅ VERIFICA CODICE: Dove φ Appare nel Codice

Il codice implementa esattamente quanto descritto in questo documento:

| Concetto | Formula | Implementazione |
|----------|---------|-----------------|
| Soglia autocorrelazione | 1/φ² | `threshold = PHI_INV_SQ` |
| Periodo veloce | base × 1/φ | `base * PHI_INV` |
| Periodo lento | base × φ | `base * PHI` |
| Scale oscillatori | stdev × φ | `*_stdev * PHI` (RSI, CCI, Stoch, Mom, MFI, WPR, AO) |
| Soglia score | mean + stdev × 1/φ | `mean + stdev * PHI_INV` |
| Margine zona Hurst | stdev × 1/φ | `g_hurstStdev * PHI_INV` |
| Range Hurst valido | [1/φ³, 1-1/φ³] | `[PHI_INV_CUB, 1.0 - PHI_INV_CUB]` |
| Buffer Hurst | φ¹⁰ ≈ 123 | `MathPow(PHI, 10)` |
| Buffer score | φ¹² ≈ 322 | `MathPow(PHI, 12)` |
| Scale R/S | φ⁵...φ⁹ | `MathPow(PHI, 5)` ... `MathPow(PHI, 9)` |
| Min barre analisi | φ⁴ ≈ 7 | `PHI_SQ * PHI_SQ` |

**Il codice è la realizzazione diretta di queste specifiche.** ✅

---

## ✅ Checklist: Cosa è Autocalcolato?

| Elemento | Autocalcolato? | Da Dove? |
|----------|----------------|----------|
| Periodo EMA | ✅ | Autocorrelazione prezzi |
| Periodo RSI | ✅ | Autocorrelazione × φ |
| Periodo MACD | ✅ | Autocorrelazione × potenze φ |
| Centro RSI | ✅ | Media storica RSI |
| Centro CCI | ✅ | Media storica CCI |
| **Centro Hurst** | ✅ | **Media storica H (NON 0.5!)** |
| Soglia ADX | ✅ | Media + stdev × φ⁻¹ |
| Peso M5 | ✅ | Hurst_M5 / Σ(Hurst) |
| Peso H1 | ✅ | Hurst_H1 / Σ(Hurst) |
| Soglia score | ✅ | Media + stdev × φ⁻¹ |
| Zona no-trade | ✅ | Centro Hurst ± stdev × φ⁻¹ |

---

## 🎓 Riassunto Concettuale

Il mercato può essere visto come un **sistema pulsante**:

### 1. 🫀 Identifica il Ritmo
Per prima cosa, analizziamo l'autocorrelazione per determinare il ciclo naturale del mercato.
```
Autocorrelazione → scende sotto 38.2% al lag 15 → periodo naturale = 15 barre
```

### 2. 🌻 Scala con φ
Il rapporto aureo φ = 1.618 fornisce proporzioni naturali e non arbitrarie.
```
Periodo veloce = 15 × φ⁻¹ = 15 × 0.618 = 9 barre
Periodo medio  = 15 × 1 = 15 barre
Periodo lento  = 15 × φ = 15 × 1.618 = 24 barre
```

### 3. 🎹 Ogni Indicatore Deriva dal Periodo Naturale
RSI usa periodo 24 (naturale × φ), MACD usa 15/39 (fast/slow), EMA usa 24...
Tutti derivati dal periodo naturale attraverso potenze di φ.

### 4. ⚖️ Ponderazione Multi-Timeframe
M5 segnala BUY, H1 è neutrale, D1 segnala BUY forte.
I pesi sono proporzionali all'Esponente di Hurst di ogni TF.
TF con H alto (trending) → peso maggiore; TF con H in zona random → peso minore.

### 5. 🗳️ Sistema di Voto
Ogni indicatore produce un voto continuo [-1.0, +1.0] basato sulla distanza dal centro empirico:
```
RSI attuale = 58, centro empirico = 48, scala = 19
Voto RSI = (58 - 48) / 19 = +0.53 (moderatamente bullish)
```

### 6. 📊 Aggregazione Score
```
Score_totale = Σ(voti_TF × peso_TF)
Score% = |Score_totale| / MaxScore × 100
Se Score% ≥ soglia dinamica → TRADE (BUY se positivo, SELL se negativo)
```

### 7. 🚦 Filtro Hurst
Verifica del regime di mercato:
- H nella zona random (centro ± stdev × φ⁻¹) → Trade bloccato
- H fuori dalla zona random → Trade permesso

---

## 🌟 IL GRANDE SEGRETO

**Non abbiamo inventato NESSUN numero!**

| Cosa | Tradizionale | Noi |
|------|--------------|-----|
| Periodo RSI | "14" (chi l'ha deciso?) | Periodo naturale × φ (dal mercato!) |
| Centro RSI | "50" (perché 50?) | Media storica del RSI (dal mercato!) |
| Soglia trade | "70/30" (arbitrario!) | Media + stdev × φ⁻¹ (dal mercato!) |

**Tutto viene da:**
1. I **DATI** del mercato (prezzi, volumi)
2. Il **RAPPORTO AUREO** φ per le scale

**E basta! 🌱**

---

*Documento generato automaticamente per EA Organic Jarvis v4.00*
*Tutti i valori sono derivati dai dati di mercato, usando solo φ come fattore di scala*
