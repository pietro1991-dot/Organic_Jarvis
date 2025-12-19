# EA Jarvis v4.0 - Guida al Backtesting

**Versione:** 4.00  
**Data:** Dicembre 2025  
**Autori:** Pietro Giacobazzi, Juri Corradi, Alessandro Brehas

---

## Introduzione

Questa guida spiega come configurare correttamente EA Jarvis per il backtesting in MetaTrader 5, con particolare attenzione a:

1. **Regole di configurazione dei timeframe** - quali attivare e quali disattivare
2. **Parametri di test consigliati** - TP, SL, Time Stop
3. **Ottimizzazioni per macchine con risorse limitate** - RecalcEveryBars
4. **Interpretazione dei risultati** - cosa cercare nei report

> **Nota importante:** EA Jarvis è un sistema "100% organico", il che significa che tutti i parametri degli indicatori vengono calcolati automaticamente dai dati di mercato. Non è necessario ottimizzare periodi RSI, EMA, etc. - il sistema li calcola da solo.

---

## 🎯 Regole Fondamentali di Configurazione

### Regola 1: Timeframe Inferiore Sempre Disattivato

Quando si testa su un timeframe specifico, **i timeframe inferiori devono essere disattivati** e **i timeframe superiori devono essere attivati**.

#### Esempio per Test su H1:

| Parametro     | Valore          | Motivo                      |
| ------------- | --------------- | --------------------------- |
| EnableVote_M5 | **false** | TF inferiore → DISATTIVATO |
| EnableVote_H1 | **true**  | TF operativo → ATTIVATO    |
| EnableVote_H4 | **true**  | TF superiore → ATTIVATO    |
| EnableVote_D1 | **true**  | TF superiore → ATTIVATO    |

#### Esempio per Test su H4:

| Parametro     | Valore          | Motivo                      |
| ------------- | --------------- | --------------------------- |
| EnableVote_M5 | **false** | TF inferiore → DISATTIVATO |
| EnableVote_H1 | **false** | TF inferiore → DISATTIVATO |
| EnableVote_H4 | **true**  | TF operativo → ATTIVATO    |
| EnableVote_D1 | **true**  | TF superiore → ATTIVATO    |

**Perché?** I timeframe superiori forniscono il contesto di trend mentre il timeframe operativo genera i segnali. I timeframe inferiori introdurrebbero rumore nel sistema.

---

## ⚙️ Parametri Consigliati per il Test

### Stop Loss e Take Profit

| Parametro            | Valore Consigliato                |
| -------------------- | --------------------------------- |
| BuyTakeProfitPoints  | **500**                     |
| SellTakeProfitPoints | **500**                     |
| BuyStopLossPoints    | **0** (usa Time Stop)       |
| SellStopLossPoints   | **0** (usa Time Stop)       |
| BuyTimeStopMinutes   | **7200** (5 giorni trading) |
| SellTimeStopMinutes  | **7200** (5 giorni trading) |

**Nota:** Con SL a 0 punti e Time Stop a 7200 minuti, le posizioni vengono chiuse al raggiungimento del TP (500 punti) o dopo 5 giorni di trading, qualunque condizione si verifichi prima.

---

## 🚀 Ottimizzazione Performance (RecalcEveryBars)

### Il Problema: Risorse Limitate

Il calcolo dell'Esponente di Hurst e del periodo naturale è computazionalmente intensivo. Su macchine con risorse limitate, il backtest può essere estremamente lento o addirittura fallire.

### La Soluzione: RecalcEveryBars

Il parametro `RecalcEveryBars` controlla ogni quante barre viene eseguito il ricalcolo completo del sistema organico.

| Valore        | Velocità    | Precisione  | Uso Consigliato                         |
| ------------- | ------------ | ----------- | --------------------------------------- |
| 0             | Molto lenta  | Massima     | Macchine potenti, test finali           |
| 50            | Media        | Alta        | Macchine medie                          |
| 100           | Veloce       | Buona       | Backtest esplorativi                    |
| **200** | Molto veloce | Accettabile | **Macchine con risorse limitate** |
| 500           | Estrema      | Bassa       | Solo screening iniziale                 |

### Configurazione per Macchine Limitate

Se il tuo computer ha:

- **RAM < 8GB** → Usa `RecalcEveryBars = 200` o superiore
- **CPU datata** → Usa `RecalcEveryBars = 200` o superiore
- **Backtest molto lunghi (>5 anni)** → Usa `RecalcEveryBars = 200`

### Configurazione per Macchine Potenti

Se il tuo computer ha:

- **RAM ≥ 16GB** e **CPU moderna** → Puoi usare `RecalcEveryBars = 0` o `50`
- Questo garantisce che il sistema organico si adatti in tempo reale alle condizioni di mercato

### L'Ideale: RecalcEveryBars = 0

In un mondo ideale con risorse illimitate, il valore ottimale è **0** perché:

- Il sistema ricalcola tutto ad ogni barra
- I periodi naturali si adattano immediatamente ai cambi di regime
- I pesi Hurst riflettono le condizioni attuali del mercato
- Le soglie dinamiche sono sempre aggiornate

**Il valore 200 è un compromesso** necessario per completare backtest su macchine normali in tempi ragionevoli.

---

## 📊 Configurazione Completa Consigliata

### Per Test su H1/H4 (Macchine Limitate)

```
═══ GENERALE ═══
enableTrading = true
MaxOpenTrades = 100
MaxSpread = 35
MaxSlippage = 40

═══ ORDINI BUY ═══
BuyLotSize = 0.5
BuyStopLossPoints = 0
BuyTakeProfitPoints = 500
StopLossPriceBuy = 0.0
TakeProfitPriceBuy = 0.0
BuyTimeStopMinutes = 7200

═══ ORDINI SELL ═══
SellLotSize = 0.5
SellStopLossPoints = 0
SellTakeProfitPoints = 500
StopLossPriceSell = 0.0
TakeProfitPriceSell = 0.0
SellTimeStopMinutes = 7200

═══ TIMEFRAME ═══
EnableIndicatorVoteSystem = true
EnableVote_M5 = false          ⚠️ SEMPRE DISATTIVATO per H1/H4
EnableVote_H1 = true           ✅ Attivare se test su H1 o superiore
EnableVote_H4 = true           ✅ Sempre attivato
EnableVote_D1 = true           ✅ Sempre attivato

═══ SISTEMA ORGANICO ═══
EnableHurstFilter = true
AutoScoreThreshold = true
ScoreThreshold = 61.8

═══ PERFORMANCE BACKTEST ═══
RecalcEveryBars = 200          🚀 Adattare in base alla tua macchina
EnableLogs = true              📝 Auto-disabilitato in backtest
```

---

## ⚠️ Limitazioni da Considerare

### 1. RecalcEveryBars Alto = Adattamento Ritardato

Con `RecalcEveryBars = 200`:

- Il sistema organico viene aggiornato ogni 200 barre
- In H1, questo significa ogni ~8 giorni
- In H4, questo significa ogni ~33 giorni

**Implicazione:** I cambi di regime del mercato vengono rilevati con ritardo. In live trading o su macchine potenti, usare valori più bassi.

### 2. Pre-caricamento Buffer

L'EA pre-carica il buffer Hurst dai dati storici per permettere trading immediato. Questo processo è ottimizzato ma richiede comunque qualche secondo all'avvio.

### 3. Warm-up Soglia Score

La soglia automatica del score (`AutoScoreThreshold = true`) richiede un minimo di ~76 campioni per essere calcolata. Prima di questo, viene usata la soglia manuale come fallback.

---

## 🔧 Risoluzione Problemi

### Backtest Troppo Lento

1. Aumentare `RecalcEveryBars` (es. da 200 a 500)
2. Ridurre il periodo di test
3. Disabilitare timeframe non necessari

### Backtest si Blocca / Timeout

1. `RecalcEveryBars` troppo basso per la macchina
2. Periodo storico troppo lungo
3. Troppi indicatori attivi simultaneamente

### Nessun Trade Eseguito

1. Verificare che `enableTrading = true`
2. Controllare che almeno un TF sia attivato
3. Il filtro Hurst potrebbe bloccare (mercato random)
4. Soglia score troppo alta

### Log: "Dati insufficienti"

Il timeframe non ha abbastanza barre storiche. Verificare che MT5 abbia scaricato la storia per tutti i TF necessari.

---

## 📈 Best Practices

1. **Test Progressivo**: Inizia con periodi brevi (1 anno) e `RecalcEveryBars = 200`, poi aumenta gradualmente
2. **Validazione Finale**: Una volta trovata una configurazione promettente, ri-testa con `RecalcEveryBars = 0` su macchina potente
3. **Multi-Timeframe**: Testa separatamente H1 e H4 prima di decidere il TF operativo
4. **Walk-Forward**: Dividi il dataset in periodi per validazione out-of-sample
5. **Simboli Diversi**: I parametri organici si adattano automaticamente, ma verifica su più coppie

---

## 📊 Interpretazione dei Risultati

### Metriche Chiave da Osservare

| Metrica          | Significato                      | Valore Buono |
| ---------------- | -------------------------------- | ------------ |
| Profit Factor    | Profitti lordi / Perdite lorde   | > 1.5        |
| Recovery Factor  | Profitto netto / Max Drawdown    | > 2.0        |
| Sharpe Ratio     | Rendimento / Volatilità         | > 1.0        |
| % Trade Vincenti | Trade in profitto / Trade totali | > 45%        |
| Max Drawdown     | Massima perdita dal picco        | < 20%        |

### Log da Monitorare

Durante il backtest, osserva questi messaggi nei log:

| Messaggio          | Significato                     |
| ------------------ | ------------------------------- |
| `✅ TRADE OK`    | Trade permesso dal filtro Hurst |
| `⛔ BLOCCATO`    | Trade bloccato (mercato random) |
| `⏳ ATTESA DATI` | Warm-up buffer in corso         |
| `Score X% >= Y%` | Trade eseguito sopra soglia     |
| `TIME STOP`      | Posizione chiusa per timeout    |

### Quando il Filtro Hurst Blocca Troppo

Se vedi molti `⛔ BLOCCATO`:

- Il mercato era effettivamente in regime random
- Questo è un comportamento **desiderato** - evita trade su rumore
- In condizioni trending vedrai più `✅ TRADE OK`

---

## ✅ Checklist Pre-Test

- [ ] TF inferiori disattivati
- [ ] TF superiori attivati
- [ ] TP impostato (500 punti)
- [ ] Time Stop impostato (7200 minuti)
- [ ] RecalcEveryBars adeguato alla macchina
- [ ] EnableHurstFilter attivo
- [ ] AutoScoreThreshold attivo
- [ ] enableTrading = true
- [ ] Dati storici scaricati per tutti i TF

---

*Documento generato per EA Jarvis v4.0 - Sistema di Trading 100% Organico*
*© 2025 Pietro Giacobazzi, Juri Corradi, Alessandro Brehas*
