# EA Jarvis v4.0 - Sistema di Trading 100% Organico

## Technical Paper

**Autori:** Pietro Giacobazzi, Juri Corradi, Alessandro Brehas  
**Versione:** 4.00  
**Data:** Dicembre 2025

---

# PARTE I - CAPIRE EA JARVIS

*Questa sezione spiega il funzionamento dell'EA in modo accessibile a tutti. Non servono conoscenze matematiche per capire i concetti fondamentali.*

---

## Introduzione: Perché "Organico"?

La parola "organico" non è un termine di marketing. Ha un significato preciso e fondamentale: **ogni singolo parametro del sistema viene calcolato direttamente dai dati di mercato**. Non esistono numeri fissi decisi arbitrariamente da qualcuno.

Per capire cosa significa, facciamo un confronto.

### Il problema degli EA tradizionali

Immagina un Expert Advisor classico che usa l'indicatore RSI. La regola tipica è:

- *"Se RSI scende sotto 30, il mercato è ipervenduto: compra"*
- *"Se RSI sale sopra 70, il mercato è ipercomprato: vendi"*

Ma da dove vengono quei numeri, 30 e 70? La risposta è semplice: **qualcuno li ha scelti**. Forse funzionavano bene su alcuni cross nel passato, forse sono diventati uno standard per convenzione. Ma non c'è nessuna garanzia che 30 e 70 siano i valori giusti per EUR/USD oggi, o per GBP/JPY domani.

Lo stesso vale per tutti gli altri parametri: la media mobile a 50 periodi, il MACD con 12/26/9, le Bollinger Bands a 20 periodi con deviazione 2.0. Sono numeri che "si usano", ma non derivano dal mercato specifico che stai tradando.

### L'approccio organico

EA Jarvis funziona in modo radicalmente diverso. Prima di fare qualsiasi cosa, **osserva i dati storici del mercato** e calcola quali dovrebbero essere i parametri ottimali per quel cross specifico, in quel momento specifico.

Tornando all'esempio RSI: invece di usare 30 e 70 fissi, l'EA:

1. Raccoglie gli ultimi N valori dell'RSI su quel cross
2. Calcola la **media** di quei valori (diciamo che risulta 52)
3. Calcola la **variabilità** tipica, cioè quanto l'RSI oscilla normalmente (diciamo ±12)
4. Usa **quei numeri** come riferimento per le decisioni

Se su un determinato cross l'RSI oscilla storicamente tra 45 e 60, usare 30 come soglia di ipervenduto non avrebbe senso: quel valore non viene quasi mai raggiunto! Invece, con l'approccio organico, la soglia si adatta automaticamente alla realtà di quel mercato.

---

## L'Unica Costante: il Rapporto Aureo

C'è un solo numero che EA Jarvis usa come costante matematica: **φ (phi), il Rapporto Aureo**, che vale circa 1.618.

Perché proprio questo numero? Perché φ non è arbitrario. È una costante matematica universale che emerge naturalmente in moltissimi fenomeni:

- La spirale del nautilo e di molte conchiglie
- La disposizione dei semi nel girasole
- Le proporzioni del corpo umano
- La sequenza di Fibonacci (1, 1, 2, 3, 5, 8, 13...) dove ogni numero diviso per il precedente tende a φ
- Le proporzioni dell'architettura classica (il Partenone)

Questa costante viene utilizzata anche nei mercati finanziari: i livelli di Fibonacci (23.6%, 38.2%, 61.8%) derivano tutti da potenze di 1/φ.

EA Jarvis usa φ **solo come fattore di scala**, non come valore assoluto. Per esempio:

- Se il "periodo naturale" del mercato è 10 barre
- L'indicatore veloce userà 10 × 0.618 ≈ 6 barre
- L'indicatore medio userà 10 × 1.000 = 10 barre
- L'indicatore lento userà 10 × 1.618 ≈ 16 barre

Ma quel 10 (il periodo naturale) non è fisso: **viene calcolato dai dati**, come vedremo.

---

## Come viene calcolato il "Periodo Naturale"

Ogni mercato ha un suo ritmo. Alcuni sono veloci e cambiano direzione ogni poche barre, altri sono lenti e mantengono trend per molte barre. EA Jarvis cerca di scoprire qual è il ritmo naturale del mercato in esame.

### L'idea dell'autocorrelazione

L'autocorrelazione risponde a una domanda semplice: **quanto il prezzo di oggi è influenzato dal prezzo di ieri?** O di due giorni fa? O di dieci giorni fa?

- Se il prezzo di oggi è molto simile a quello di ieri, l'autocorrelazione è alta: il mercato ha "memoria"
- Se il prezzo di oggi non ha relazione con quello di ieri, l'autocorrelazione è bassa: il mercato ha "dimenticato"

EA Jarvis analizza l'autocorrelazione a diversi "lag" (ritardi): 1 barra, 2 barre, 3 barre, e così via. All'inizio l'autocorrelazione sarà alta (il prezzo di 1 barra fa è molto correlato con quello attuale), poi scenderà man mano che si va indietro nel tempo.

### La soglia di "dimenticanza"

Il punto chiave è: **a quale lag l'autocorrelazione diventa abbastanza bassa da considerare che il mercato ha "dimenticato"?**

Qui entra in gioco φ. La soglia usata è **1/φ² ≈ 0.382** (il famoso livello di Fibonacci 38.2%). Quando l'autocorrelazione scende sotto questo valore, consideriamo che il mercato ha perso memoria del passato.

Il lag a cui questo accade diventa il **periodo naturale**. Per esempio:
- Se l'autocorrelazione scende sotto 0.382 al lag 12, il periodo naturale è 12 barre
- Se scende sotto 0.382 al lag 8, il periodo naturale è 8 barre

Questo numero **cambia automaticamente** in base al mercato e al momento. Un mercato molto trending avrà un periodo naturale lungo (alta memoria), un mercato caotico avrà un periodo naturale corto (bassa memoria).

---

## L'Esponente di Hurst: Capire il Regime del Mercato

Questa è una delle parti più innovative di EA Jarvis. Prima di decidere se entrare a mercato, l'EA si chiede: **"Il mercato è prevedibile in questo momento, o è puro rumore?"**

### Cos'è l'Esponente di Hurst

L'Esponente di Hurst (che chiameremo H) è un numero che misura il "comportamento" di una serie di prezzi:

- **H alto**: il mercato tende a continuare nella direzione attuale (trending)
- **H basso**: il mercato tende a invertire, tornando verso la media (mean-reverting)
- **H medio**: il mercato si muove in modo casuale, senza pattern prevedibili (random)

### Il valore 0.5 NON è fisso!

Qui arriviamo a un punto cruciale. Potresti aver letto che "H = 0.5 indica un random walk". Ma in EA Jarvis, **anche il centro di riferimento viene calcolato dai dati**, non è fissato a 0.5!

Ecco come funziona:

1. L'EA calcola H continuamente, ad ogni nuova barra
2. Tiene uno storico degli ultimi ~123 valori di H (questo numero deriva da φ¹⁰ ≈ 123)
3. Calcola la **media** di questi valori storici: questo diventa il **centro**
4. Calcola la **deviazione standard** (quanto i valori oscillano attorno alla media)
5. La "zona random" diventa: **centro ± (deviazione standard × 1/φ)**

Facciamo un esempio concreto:
- Supponiamo che su EUR/USD, negli ultimi 123 calcoli, H abbia avuto media 0.52 e deviazione standard 0.08
- Il margine sarà: 0.08 × 0.618 ≈ 0.05
- La zona random sarà: [0.52 - 0.05, 0.52 + 0.05] = [0.47, 0.57]

Quindi su quel cross, l'EA considererà:
- H > 0.57 → Mercato trending → Trade permessi
- H < 0.47 → Mercato mean-reverting → Trade permessi
- 0.47 < H < 0.57 → Mercato random → **Trade bloccati**

Su un altro cross, magari la media storica di H è 0.48 invece di 0.52, e quindi la zona random sarà diversa. **Tutto si adatta al mercato specifico.**

### Perché bloccare i trade quando il mercato è random?

Immagina di lanciare una moneta equa. Puoi prevedere se uscirà testa o croce? No, è 50/50. Non c'è edge, non c'è vantaggio statistico.

Quando il mercato è in regime random (H nella zona centrale), **qualsiasi segnale tecnico è essenzialmente rumore**. L'RSI, il MACD, le medie mobili... tutti generano segnali, ma quei segnali non hanno potere predittivo.

EA Jarvis riconosce questa situazione e semplicemente **non opera**. Aspetta che il mercato esca dalla zona random prima di aprire nuove posizioni.

---

## Il Sistema di Voto Multi-Indicatore

Una volta che EA Jarvis ha calcolato tutti i parametri organici e verificato che il mercato non è in regime random, deve decidere la direzione: comprare o vendere?

### 18 indicatori che "votano"

L'EA usa 18 indicatori tecnici diversi. Ognuno esprime un **voto continuo** tra -1.0 e +1.0:

- **+1.0** = segnale BUY molto forte
- **+0.5** = segnale BUY moderato
- **0** = neutrale
- **-0.5** = segnale SELL moderato
- **-1.0** = segnale SELL molto forte

Questo approccio continuo (invece di semplici +1/0/-1) cattura le **sfumature** di ogni indicatore. Un RSI a 75 darà un voto più forte di un RSI a 52, non lo stesso voto.

Ma i voti non sono tutti uguali. Ci sono due livelli di ponderazione:

### 1. Peso del timeframe

EA Jarvis analizza 4 timeframe: M5 (5 minuti), H1 (1 ora), H4 (4 ore), D1 (1 giorno).

Ogni timeframe riceve un peso basato sul suo Esponente di Hurst:

**peso_TF = H_TF / somma di tutti gli H**

In pratica: se il timeframe H4 è molto trending (H alto) mentre M5 è caotico (H basso), i segnali di H4 conteranno di più nella decisione finale. Questo perché i segnali di un timeframe trending sono più affidabili.

### 2. Centri empirici per ogni indicatore

Ogni indicatore ha bisogno di un "centro" per decidere se è bullish o bearish. Per esempio:

**RSI tradizionale**: sopra 50 è bullish, sotto 50 è bearish (50 è il centro)

**RSI organico**: l'EA calcola la media storica dell'RSI su quel cross. Se risulta 47, allora:
- RSI > 47 → bullish
- RSI < 47 → bearish

Questo viene fatto per ogni oscillatore: CCI, Stochastic, Williams %R, MFI, Momentum. **Nessun valore fisso**, tutto calcolato dai dati.

### 3. Soglia ADX dinamica

L'ADX misura la forza del trend. Tradizionalmente si dice "ADX > 25 indica trend forte".

In EA Jarvis, la soglia viene calcolata così:

**soglia_ADX = media_ADX + (deviazione_standard_ADX × 1/φ)**

Se su un cross l'ADX oscilla storicamente tra 15 e 35 con media 22 e stdev 6:
- soglia = 22 + (6 × 0.618) ≈ 26

Ma su un altro cross dove l'ADX è storicamente più alto, la soglia sarà diversa.

### 4. Lo score finale

Tutti i voti vengono sommati, pesati per timeframe, e si ottiene uno score finale. Ma anche qui, la **soglia per decidere se tradare è auto-calcolata**:

- L'EA tiene uno storico degli score passati
- Calcola media e deviazione standard
- La soglia è: **media_score + deviazione_standard × 1/φ**

Solo se lo score supera questa soglia, viene aperto un trade.

---

## I Periodi degli Indicatori

Ogni indicatore tecnico ha uno o più "periodi" che determinano quanto indietro nel tempo guarda. Per esempio, una EMA a 20 periodi usa le ultime 20 barre.

### Derivazione dal periodo naturale

In EA Jarvis, tutti i periodi derivano dal **periodo naturale** (calcolato dall'autocorrelazione) usando potenze di φ:

| Velocità | Moltiplicatore | Esempio (se naturale = 10) |
|----------|---------------|---------------------------|
| Molto veloce | × 0.382 (1/φ²) | ≈ 4 barre |
| Veloce | × 0.618 (1/φ) | ≈ 6 barre |
| Medio | × 1.000 | = 10 barre |
| Lento | × 1.618 (φ) | ≈ 16 barre |
| Molto lento | × 2.618 (φ²) | ≈ 26 barre |
| Lunghissimo | × 4.236 (φ³) | ≈ 42 barre |

### Assegnazione logica

Gli indicatori vengono assegnati a queste velocità in base alla loro funzione:

- **Indicatori di trend** (che devono catturare movimenti ampi): periodi lenti
  - EMA → lento (φ)
  - SMA 50 → molto lento (φ²)
  - SMA 200 → lunghissimo (φ³)

- **Indicatori di momentum** (che devono reagire velocemente): periodi medi
  - RSI → medio (1)
  - Momentum → medio (1)
  - CCI → lento (φ)

- **MACD** (che ha tre componenti in relazione tra loro):
  - Fast → veloce (1/φ)
  - Slow → lento (φ)
  - Signal → molto veloce (1/φ²)

E così via per tutti i 18 indicatori.

---

## Il Flusso Decisionale Completo

Mettiamo insieme tutti i pezzi. Quando arriva una nuova candela, EA Jarvis esegue questi passaggi:

### Step 1: Ricalcolo del sistema organico

- Calcola il periodo naturale per ogni timeframe (dall'autocorrelazione)
- Calcola l'Esponente di Hurst per ogni timeframe
- Aggiorna i pesi dei timeframe (basati su Hurst)
- Ricalcola i periodi di tutti gli indicatori (basati sul periodo naturale)
- Aggiorna i centri empirici di tutti gli oscillatori

### Step 2: Verifica ready check

L'EA verifica che i buffer Hurst e TradeScore siano stati pre-caricati correttamente dallo storico in `OnInit()`. Se il pre-caricamento è riuscito, il trading può iniziare immediatamente. In caso contrario, l'EA accumula dati incrementalmente fino a raggiungere le soglie minime.

### Step 3: Filtro Hurst

Calcola H composito (media pesata degli H di tutti i TF) e verifica:
- Se H è nella zona random → **STOP, non tradare**
- Se H è fuori dalla zona random → prosegui

### Step 4: Raccolta voti

Per ogni timeframe attivo, per ogni indicatore abilitato:
- Leggi il valore corrente dell'indicatore
- Confrontalo con il suo centro empirico
- Assegna voto +1, 0 o -1

### Step 5: Calcolo score

- Somma tutti i voti pesandoli per timeframe
- Calcola la percentuale rispetto al massimo possibile
- Confronta con la soglia (auto-calcolata o manuale)

### Step 6: Decisione

- Se score% ≥ soglia e score > 0 → **APRI BUY**
- Se score% ≥ soglia e score < 0 → **APRI SELL**
- Altrimenti → **ASPETTA**

---

## Gestione delle Posizioni

Una volta aperto un trade, EA Jarvis gestisce:

### Stop Loss e Take Profit

Configurabili in due modi (con priorità al prezzo fisso):
- **In punti**: SL/TP a distanza fissa dal prezzo di ingresso
- **Prezzo fisso**: SL/TP a un prezzo specifico

### Time Stop

Una funzionalità opzionale che chiude automaticamente le posizioni dopo un certo numero di minuti. Utile per:
- Evitare di restare bloccati in trade che non vanno da nessuna parte
- Limitare l'esposizione temporale al mercato

### Filtri pre-trade

Prima di aprire ogni posizione, l'EA verifica:
- Spread ≤ MaxSpread configurato
- Numero posizioni aperte < MaxOpenTrades
- Trading abilitato (enableTrading = true)

---

## Riepilogo: Cosa Viene Auto-Calcolato

Per ricapitolare, ecco **tutto** ciò che EA Jarvis calcola automaticamente dai dati:

| Parametro | Come viene calcolato |
|-----------|---------------------|
| Periodo naturale | Lag dove autocorrelazione < 1/φ² |
| Periodi indicatori | Periodo naturale × potenze di φ |
| Pesi timeframe | H_TF / somma(H_tutti_TF) |
| Centro zona Hurst | Media storica di H |
| Margine zona Hurst | StdDev(H) × 1/φ |
| Centro RSI | Media storica RSI |
| Centro CCI | Media storica CCI |
| Centro Stochastic | Media storica Stoch |
| Centro WPR | Media storica WPR |
| Centro MFI | Media storica MFI |
| Centro Momentum | Media storica Mom |
| Soglia ADX | Media ADX + StdDev × 1/φ |
| Soglia score | Media score + StdDev × 1/φ |
| Deviazione Bollinger | Formula organica basata su periodo naturale |
| Step/Max PSAR | Formule organiche inversamente proporzionali al periodo |

**Nessun valore è hardcodato.** L'unica costante è φ = 1.618, usata solo come fattore di scala.

---

## Confronto con EA Tradizionali

| Aspetto | EA Tradizionale | EA Jarvis |
|---------|-----------------|-----------|
| RSI ipervenduto | 30 (fisso) | Media storica - margine (calcolato) |
| RSI ipercomprato | 70 (fisso) | Media storica + margine (calcolato) |
| Periodo EMA | 20 (fisso) | Periodo naturale × φ (calcolato) |
| Periodo RSI | 14 (fisso) | Periodo naturale (calcolato) |
| Soglia ADX | 25 (fisso) | Media + StdDev × 1/φ (calcolato) |
| Centro Hurst | 0.5 (fisso) | Media storica H (calcolato) |
| Zona random Hurst | 0.45-0.55 (fisso) | Centro ± StdDev × 1/φ (calcolato) |
| Peso timeframe | Uguale o arbitrario | Basato su Hurst (calcolato) |
| Soglia score | Fissa (es. 60%) | Media + StdDev × 1/φ (calcolato) |

---

# PARTE II - SPECIFICHE TECNICHE

*Questa sezione contiene le formule matematiche e i dettagli implementativi per sviluppatori e quant.*

---

## 1. Costanti Matematiche

L'unica costante del sistema:

$$\phi = \frac{1 + \sqrt{5}}{2} \approx 1.618033988749895$$

Derivate:
- $\phi^{-1} = \phi - 1 \approx 0.618$ (livello Fibonacci 61.8%)
- $\phi^{-2} = \phi^{-1} \cdot \phi^{-1} \approx 0.382$ (livello Fibonacci 38.2%)
- $\phi^{-3} \approx 0.236$ (livello Fibonacci 23.6%)
- $\phi^{2} = \phi + 1 \approx 2.618$
- $\phi^{3} \approx 4.236$

---

## 2. Autocorrelazione e Periodo Naturale

### Formula autocorrelazione

$$r(k) = \frac{\sum_{i=k}^{N}(P_i - \bar{P})(P_{i-k} - \bar{P})}{\sum_{i=1}^{N}(P_i - \bar{P})^2}$$

Dove:
- $r(k)$ = coefficiente di autocorrelazione al lag $k$
- $P_i$ = prezzo di chiusura alla barra $i$
- $\bar{P}$ = media dei prezzi
- $N$ = numero di barre

### Criterio di selezione

$$\text{naturalPeriod} = \min\{k : r(k) < \phi^{-2}\}$$

### Fallback

Se nessun lag soddisfa il criterio:
1. Cerca il primo minimo locale di $r(k)$
2. Se non trovato: $\text{naturalPeriod} = \text{maxLag} / \phi$

---

## 3. Esponente di Hurst (Metodo R/S)

### Scale Fisse

L'implementazione usa **5 scale fisse** derivate dalle potenze **esatte** di φ:

| Scala | Valore | Derivazione |
|-------|--------|-------------|
| 1 | 11 | round(φ⁵) = round(11.09) |
| 2 | 18 | round(φ⁶) = round(17.94) |
| 3 | 29 | round(φ⁷) = round(29.03) |
| 4 | 47 | round(φ⁸) = round(46.98) |
| 5 | 76 | round(φ⁹) = round(76.01) |

Questa progressione garantisce una copertura uniforme in scala logaritmica, con ogni scala che è esattamente φ volte la precedente.

### Algoritmo

Per ogni scala $n$ in [11, 18, 29, 47, 76]:

1. Dividi la serie in blocchi di $n$ elementi
2. Per ogni blocco calcola:
   - Media: $\bar{X}_n = \frac{1}{n}\sum_{i=1}^{n}X_i$
   - Deviazione cumulativa: $Y_i = \sum_{j=1}^{i}(X_j - \bar{X}_n)$
   - Range: $R = \max(Y) - \min(Y)$
   - StdDev: $S = \sqrt{\frac{1}{n}\sum(X_i - \bar{X}_n)^2}$
3. Media R/S per ogni scala
4. Regressione: $\log(R/S) = H \cdot \log(n) + c$

La pendenza $H$ è l'Esponente di Hurst.

### Formula regressione

$$H = \frac{n \sum x_i y_i - \sum x_i \sum y_i}{n \sum x_i^2 - (\sum x_i)^2}$$

Dove $x_i = \log(n_i)$ e $y_i = \log(R/S_i)$

---

## 4. Zona No-Trade Adattiva

### Calcolo soglie

$$\text{centro}_H = \bar{H} = \frac{1}{N}\sum_{i=1}^{N}H_i$$

$$\sigma_H = \sqrt{\frac{1}{N}\sum_{i=1}^{N}(H_i - \bar{H})^2}$$

$$\text{margine} = \sigma_H \cdot \phi^{-1}$$

$$\text{zona\_random} = [\bar{H} - \text{margine}, \bar{H} + \text{margine}]$$

### Trade Score

$$\text{confidenza} = \min\left(1.0, \frac{|H - \bar{H}|}{\sigma_H \cdot \phi}\right)$$

$$\text{tradeScore} = \frac{|H - \bar{H}| \cdot \text{confidenza}}{\sigma_H \cdot \phi}$$

---

## 5. Pesi Multi-Timeframe

### Formula

$$w_{TF} = \frac{H_{TF}}{\sum_{i \in \{M5, H1, H4, D1\}} H_i}$$

### Hurst composito

$$H_{comp} = \frac{\sum_{TF} H_{TF} \cdot w_{TF}}{\sum_{TF} w_{TF}}$$

---

## 6. Periodi Organici

### Scala

| Categoria | Formula | Valore |
|-----------|---------|--------|
| veryFast | base × φ⁻² | 0.382 |
| fast | base × φ⁻¹ | 0.618 |
| medium | base × 1 | 1.000 |
| slow | base × φ | 1.618 |
| verySlow | base × φ² | 2.618 |
| longest | base × φ³ | 4.236 |

### Assegnazione

```cpp
// TREND
organic.ema = slow;               // EMA: segue il trend
organic.sma50 = verySlow;         // SMA breve: struttura intermedia
organic.sma200 = longest;         // SMA lunga: struttura principale

// MOMENTUM
organic.rsi = medium;             // RSI: reattivo
organic.cci = slow;               // CCI: ciclico
organic.momentum = medium;        // Momentum: rate of change

// MACD (proporzioni auree)
organic.macd_fast = fast;         // Componente veloce
organic.macd_slow = slow;         // Componente lenta
organic.macd_signal = veryFast;   // Linea di segnale

// STOCHASTIC (proporzioni auree)
organic.stoch_k = medium;         // Linea K
organic.stoch_d = fast;           // Linea D (più smooth)
organic.stoch_slowing = veryFast; // Slowing

// VOLATILITÀ
organic.bb = slow;                // Bollinger Bands
organic.atr = medium;             // ATR
organic.adx = medium;             // ADX

// ALTRI OSCILLATORI
organic.wpr = medium;             // Williams %R
organic.mfi = medium;             // Money Flow Index

// CANALI
organic.donchian = verySlow;      // Donchian Channel

// ICHIMOKU
organic.ichimoku_tenkan = medium; // Tenkan-sen
organic.ichimoku_kijun = verySlow;// Kijun-sen
organic.ichimoku_senkou = longest;// Senkou Span B

// PARABOLIC SAR (formule inverse)
organic.psar_step = φ⁻¹ / (base × φ)  // Inversamente proporzionale
organic.psar_max = φ⁻¹ / base         // Più alto per mercati veloci
```

---

## 7. Centri Empirici

### Formula generale

$$\text{centro}_{ind} = \bar{X}_{ind} = \frac{1}{N}\sum_{i=1}^{N}X_{ind,i}$$

$$\text{scala}_{ind} = \sigma_{ind} \cdot \phi$$

### Soglia ADX

$$\text{ADX}_{threshold} = \bar{ADX} + \sigma_{ADX} \cdot \phi^{-1}$$

---

## 8. Sistema di Voto e Normalizzazione Score

### Normalizzazione Continua

A differenza di sistemi tradizionali che usano voti discreti (+1, 0, -1), EA Jarvis implementa una **normalizzazione continua** dove ogni indicatore produce un valore nell'intervallo **[-1.0, +1.0]**.

### Formula Normalizzazione per Indicatore

Per oscillatori con centro empirico:
$$v_{ind} = \text{clamp}\left(\frac{X_{ind} - \text{centro}_{ind}}{\text{scala}_{ind}}, -1, +1\right)$$

Per indicatori di prezzo (EMA, PSAR, Ichimoku):
$$v_{ind} = \text{clamp}\left(\frac{\text{Price} - \text{Indicatore}}{\text{ATR}_{avg} \times \phi}, -1, +1\right)$$

Dove `clamp(x, a, b)` forza il valore nel range [a, b].

### Score per Timeframe

$$\text{Score}_{TF} = \sum_{i=1}^{18} v_i \cdot w_{TF}$$

Dove:
- $v_i \in [-1.0, +1.0]$ (valore normalizzato continuo)
- $w_{TF}$ = peso organico del timeframe (calcolato da Hurst)

### Score Totale

$$\text{Score}_{tot} = \sum_{TF \in \{M5, H1, H4, D1\}} \text{Score}_{TF}$$

Solo i timeframe abilitati contribuiscono alla somma.

### Calcolo Percentuale Score

$$\text{MaxScore} = \sum_{TF \text{ attivi}} w_{TF} \times N_{indicatori}$$

$$\text{Score}_{\%} = \frac{|\text{Score}_{tot}|}{\text{MaxScore}} \times 100$$

### Soglia Automatica (Data-Driven)

$$\text{threshold} = \bar{S} + \sigma_S \cdot \phi^{-1}$$

Dove $\bar{S}$ e $\sigma_S$ sono calcolati dal buffer storico degli score.

**Limiti organici della soglia:** $[\phi^{-3} \times 100, (1-\phi^{-3}) \times 100] \approx [23.6\%, 76.4\%]$

### Decisione Finale

```
SE Score_% >= threshold E Score_tot > 0  →  BUY
SE Score_% >= threshold E Score_tot < 0  →  SELL
ALTRIMENTI                                →  NO TRADE
```

---

## 9. Tabella Indicatori

| # | Indicatore | Logica BUY | Logica SELL |
|---|------------|------------|-------------|
| 1 | EMA | Price > EMA | Price < EMA |
| 2 | RSI | RSI > centro_emp | RSI < centro_emp |
| 3 | MACD | MACD > Signal | MACD < Signal |
| 4 | Bollinger | Price > Middle | Price < Middle |
| 5 | ADX | +DI > -DI (ADX > soglia) | -DI > +DI (ADX > soglia) |
| 6 | Stochastic | %K > %D | %K < %D |
| 7 | CCI | CCI > centro_emp | CCI < centro_emp |
| 8 | Momentum | Mom > centro_emp | Mom < centro_emp |
| 9 | PSAR | Price > SAR | Price < SAR |
| 10 | Heikin Ashi | HA_Close > HA_Open | HA_Close < HA_Open |
| 11 | Williams %R | WPR > centro_emp | WPR < centro_emp |
| 12 | Awesome Osc | AO > centro_emp | AO < centro_emp |
| 13 | OBV | OBV↑ | OBV↓ |
| 14 | MFI | MFI > centro_emp | MFI < centro_emp |
| 15 | Donchian | Close > Upper_prev | Close < Lower_prev |
| 16 | Ichimoku | Price > Cloud | Price < Cloud |
| 17 | SMA Cross | SMA50 > SMA200 | SMA50 < SMA200 |
| 18 | ATR | Alta volatilità + trend giù → BUY (contrarian) | Alta volatilità + trend su → SELL (contrarian) |

---

## 10. Buffer e Warm-Up

### Dimensioni buffer

| Buffer | Size | Derivazione |
|--------|------|-------------|
| Hurst History | 123 | round(φ¹⁰) |
| TradeScore History | 76 | round(φ⁹) |
| Score History | 322 | round(φ¹²) |
| Min samples Hurst | 47 | 123 × φ⁻² ≈ 123 × 0.382 |
| Min samples Score | 76 | 322 × φ⁻² × φ⁻¹ ≈ 24% del buffer |

### Condizioni ready

```cpp
g_hurstZoneReady = (g_hurstHistorySize >= minSamples);
g_scoreThresholdReady = (g_scoreHistorySize >= minSamples);
tfData.isDataReady = (bars >= organic.min_bars_required);
```

---

## 11. Parametri Configurabili

### Money Management

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| enableTrading | true | On/off trading |
| MaxOpenTrades | 100 | Max posizioni |
| MaxSpread | 35 | Spread massimo in punti |
| MaxSlippage | 40 | Slippage max in punti |
| MagicNumber | 123456 | ID EA |

### Ordini

| | BUY | SELL |
|--|-----|------|
| Lotto | BuyLotSize | SellLotSize |
| SL punti | BuyStopLossPoints | SellStopLossPoints |
| TP punti | BuyTakeProfitPoints | SellTakeProfitPoints |
| SL prezzo | StopLossPriceBuy | StopLossPriceSell |
| TP prezzo | TakeProfitPriceBuy | TakeProfitPriceSell |
| Time stop | BuyTimeStopMinutes | SellTimeStopMinutes |

### Timeframe

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| EnableIndicatorVoteSystem | true | Abilita sistema voti |
| EnableVote_M5 | false | Usa M5 nel voto |
| EnableVote_H1 | true | Usa H1 nel voto |
| EnableVote_H4 | true | Usa H4 nel voto |
| EnableVote_D1 | true | Usa D1 nel voto |

### Indicatori Trend

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| enableEMA | true | EMA (trend direction) |
| enableMACD | true | MACD (trend momentum) |
| enablePSAR | true | Parabolic SAR (trend reversal) |
| enableADX | true | ADX (trend strength) |
| enableSMA | true | SMA Cross (trend confirmation) |
| enableIchimoku | true | Ichimoku (multi-component trend) |

### Indicatori Oscillatori

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| enableRSI | true | RSI (overbought/oversold) |
| enableStoch | true | Stochastic (momentum oscillator) |
| enableCCI | true | CCI (cyclical momentum) |
| enableMomentum | true | Momentum (rate of change) |
| enableWPR | true | Williams %R (momentum oscillator) |
| enableAO | true | Awesome Oscillator (momentum) |

### Indicatori Volatilità & Volume

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| enableBB | true | Bollinger Bands (volatility bands) |
| enableATRsignal | true | ATR (volatility-based, contrarian) |
| enableDonchian | true | Donchian Channel (breakout) |
| enableOBV | true | OBV (volume-based trend) |
| enableMFI | true | MFI (volume-weighted momentum) |
| enableHeikin | true | Heikin Ashi (noise reduction) |

### Filtri Sistema Organico

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| EnableHurstFilter | true | Blocca trade in zona random |
| AutoScoreThreshold | true | Soglia automatica (true) o manuale (false) |
| ScoreThreshold | 61.8 | Soglia manuale (φ⁻¹ × 100) - solo se Auto=false |

### Performance Backtest

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| RecalcEveryBars | 200 | Ricalcolo ogni N barre (0=ogni barra) |
| EnableLogs | true | Abilita log dettagliati (auto-off in backtest) |

---

## 12. Ottimizzazioni Performance per Backtest

EA Jarvis include un sistema di ottimizzazione specifico per il backtesting che bilancia accuratezza e velocità.

### RecalcEveryBars - Ricalcolo Ottimizzato

Il parametro `RecalcEveryBars` controlla ogni quante barre il sistema organico viene ricalcolato completamente:

| Valore | Comportamento | Speedup |
|--------|---------------|---------|
| 0 | Ricalcolo ogni barra (massima precisione) | 1x |
| 100 | Ricalcolo ogni 100 barre | ~50x |
| 200 | Ricalcolo ogni 200 barre | ~100x |

**Nota importante:** Su macchine con risorse limitate (RAM/CPU), usare valori come 100-200 per completare backtest lunghi. Su macchine potenti, si può usare 0 o valori bassi per massima accuratezza.

### Sistema di Caching Multi-Livello

Il sistema implementa cache a più livelli:

1. **Cache Hurst**: I risultati del calcolo Hurst vengono memorizzati in `g_cachedResult_XX` e riutilizzati per `hurstRecalcInterval` cicli
2. **Cache Dati TF**: I dati dei timeframe vengono ricaricarti solo ogni `tfDataReloadInterval` barre (derivato da `RecalcEveryBars / 5`)
3. **Update Incrementale**: Tra i ricaricamenti, solo l'ultima barra viene aggiornata tramite `UpdateLastBar()`

### Pre-caricamento Buffer Hurst

Per evitare il lungo warm-up iniziale, il sistema pre-carica il buffer Hurst dai dati storici:

```cpp
void PreloadHurstBufferFromHistory()
```

Questa funzione:
1. Carica dati storici per tutti i TF disponibili
2. Calcola Hurst composito pesato per ogni campione storico
3. Riempie il buffer circolare `g_hurstHistory[]` 
4. Calcola centro, stdev e zona random
5. Pre-popola anche il buffer `g_tradeScoreHistory[]`

Risultato: Il trading può iniziare **immediatamente** invece di aspettare ~123 barre di warm-up.

### Rilevamento Automatico Modalità Backtest

```cpp
g_isBacktest = (bool)MQLInfoInteger(MQL_TESTER);
g_enableLogsEffective = EnableLogs && !g_isBacktest;
```

In backtest:
- I log dettagliati vengono automaticamente disabilitati
- Il sistema attiva le ottimizzazioni di cache
- Viene mostrato un riepilogo iniziale delle impostazioni

---

## 13. Time Stop - Chiusura Temporale

Il sistema include una funzionalità di **Time Stop** che chiude automaticamente le posizioni dopo un tempo massimo definito:

### Parametri

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| BuyTimeStopMinutes | 7200 | Chiusura BUY dopo N minuti (0=disattivato) |
| SellTimeStopMinutes | 7200 | Chiusura SELL dopo N minuti (0=disattivato) |

### Funzionamento

```cpp
void CheckAndCloseOnTimeStop()
```

Ad ogni tick:
1. Scorre tutte le posizioni aperte con MagicNumber corrispondente
2. Calcola il tempo trascorso dall'apertura
3. Se supera il limite, chiude la posizione forzatamente
4. Registra nel log il P/L della chiusura

### Utilizzo Pratico

Il Time Stop è utile per:
- Evitare posizioni "bloccate" in range
- Limitare l'esposizione temporale al rischio overnight/weekend
- Forzare rotazione del capitale
- Testing di strategie con holding period massimo definito

Con 7200 minuti (5 giorni di trading), una posizione viene chiusa al massimo dopo una settimana lavorativa.

---

## 14. Validazioni e Protezioni Implementate

Il codice include numerose validazioni per robustezza:

### Protezioni Numeriche

| Tipo | Protezione |
|------|------------|
| Divisione per zero | Check denominatore > 0 prima di ogni divisione |
| Radice negativa | `sqrt(x)` solo se x > 0, altrimenti ritorna 0 |
| Range Hurst | Output forzato in [0.1, 0.9] |
| Indici buffer | Sempre calcolati con modulo `% MAX_SIZE` |
| Floating point | Sanity check per somme incrementali (≥ 0) |

### Buffer Circolari

```cpp
g_hurstHistory[]         // 123 elementi (φ¹⁰)
g_tradeScoreHistory[]    // 76 elementi (φ⁹)
g_scoreHistory[]         // 322 elementi (φ¹²)
```

### Flag di Ready

| Flag | Significato |
|------|-------------|
| `g_hurstZoneReady` | Centro e margine Hurst calcolati |
| `g_tradeScoreReady` | Soglia tradeScore calcolata |
| `g_hurstReady` | Entrambi i precedenti pronti |
| `g_scoreThresholdReady` | Soglia score dinamica pronta |
| `tfData.isDataReady` | Dati TF sufficienti per calcoli |

---

## 15. Riferimenti Bibliografici

1. Hurst, H.E. (1951). *Long-term storage capacity of reservoirs*. Transactions of the American Society of Civil Engineers.

2. Mandelbrot, B.B. & Wallis, J.R. (1969). *Robustness of the rescaled range R/S in the measurement of noncyclic long run statistical dependence*. Water Resources Research.

3. Peters, E.E. (1994). *Fractal Market Analysis: Applying Chaos Theory to Investment and Economics*. Wiley.

4. Livio, M. (2002). *The Golden Ratio: The Story of Phi, the World's Most Astonishing Number*. Broadway Books.

---

## Glossario

| Termine | Spiegazione |
|---------|-------------|
| **Autocorrelazione** | Misura di quanto i valori passati influenzano quelli futuri. Alta = il mercato ha "memoria", bassa = casualità. |
| **Esponente di Hurst (H)** | Numero tra 0 e 1 che indica il regime del mercato. In EA Jarvis il centro NON è fisso a 0.5 ma viene calcolato dalla media storica dei valori di H. |
| **Rapporto Aureo (φ)** | Costante matematica ≈1.618, unico numero "magico" usato nel sistema. Presente ovunque in natura (spirali, fiori, galassie). |
| **Mean-reverting** | Regime di mercato dove i prezzi tendono a tornare verso un valore medio. H sotto il centro. |
| **Trending/Persistente** | Regime di mercato dove i prezzi tendono a continuare nella stessa direzione. H sopra il centro. |
| **Random walk** | Movimento casuale senza pattern prevedibile. H nella zona centrale. Nessun edge statistico. |
| **Timeframe (TF)** | Intervallo temporale del grafico: M5=5 minuti, H1=1 ora, H4=4 ore, D1=1 giorno. |
| **Warm-up** | Periodo iniziale necessario per raccogliere abbastanza dati storici prima di operare. |
| **Centro empirico** | Media storica di un indicatore, calcolata direttamente dai dati del mercato specifico. |
| **Soglia adattiva** | Livello decisionale che cambia automaticamente in base ai dati recenti. |
| **Periodo naturale** | Numero di barre dopo il quale il mercato "dimentica" i prezzi passati. Calcolato dall'autocorrelazione. |
| **R/S (Rescaled Range)** | Metodo statistico per calcolare l'Esponente di Hurst. Range diviso per deviazione standard. |
| **Normalizzazione** | Processo per convertire valori di indicatori diversi in una scala comune [-1.0, +1.0]. |
| **Time Stop** | Chiusura automatica di una posizione dopo un tempo massimo definito (es. 7200 minuti = 5 giorni). |
| **Buffer circolare** | Struttura dati che memorizza gli ultimi N valori, sovrascrivendo i più vecchi quando pieno. |
| **RecalcEveryBars** | Parametro che controlla ogni quante barre ricalcolare il sistema organico. 0=massima precisione, 200=veloce. |

---

*© 2025 Pietro Giacobazzi, Juri Corradi, Alessandro Brehas. Tutti i diritti riservati.*
