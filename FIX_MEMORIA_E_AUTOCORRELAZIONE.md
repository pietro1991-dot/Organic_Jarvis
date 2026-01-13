# FIX CRITICO: Memoria e Autocorrelazione

## Problemi Identificati dal Log

### 1. **MEMORY CRITICAL Falso Positivo** ❌
```
[MEMORY CRITICAL] Memoria critica: 0 MB disponibili! Trading sospeso temporaneamente.
```
**Causa**: `TerminalInfoInteger(TERMINAL_MEMORY_USED/TOTAL)` non funziona correttamente durante il backtest del tester MT5, ritornando sempre valori non validi (0 MB disponibili).

**Impatto**: L'EA si blocca continuamente durante il backtest credendo che la memoria sia esaurita, quando invece è solo un problema di lettura incorretta.

### 2. **Autocorrelazione Fallisce Sempre** ⚠️
```
[NATURAL] TF PERIOD_M5: nessun decay trovato, uso maxLag/2=3
[NATURAL] TF PERIOD_H1: nessun decay trovato, uso maxLag/2=3
[NATURAL] TF PERIOD_D1: nessun decay trovato, uso maxLag/2=2
```
**Causa**: Ciclo vizioso:
1. Bootstrap carica solo 42 barre (minimo statistico)
2. `maxLag = 42 × 0.15 = 6` lag disponibili
3. Autocorrelazione non trova decay con solo 6 lag
4. Fallback: `naturalPeriod = maxLag/2 = 3` periodi
5. **3 periodi sono insufficienti** per analisi significativa!

**Impatto**: Il sistema usa periodi troppo corti (2-3 barre) che non catturano la vera ciclicità del mercato.

### 3. **Barre Insufficienti Ripetute** ⚠️
```
[ORGANIC WARN] Barre insufficienti: 30 < 153 richieste
[ORGANIC WARN] Barre insufficienti: 68 < 153 richieste
[ORGANIC WARN] Barre insufficienti: 86 < 153 richieste
```
**Causa**: Il sistema entra in bootstrap con periodo=3, ma poi richiede 153 barre per l'analisi completa. Non riesce mai a "uscire" dal bootstrap.

---

## Soluzioni Implementate ✅

### **Fix 1: Disabilita Controllo Memoria in Backtest**
```mql5
// PRIMA (bugga in backtest):
if (tickCounter % 1000 == 0) {
    long memoryAvailable = memoryLimit - memoryUsed;
    if (memoryAvailable < 50 * 1024 * 1024) {
        return;  // BLOCCO CONTINUO IN BACKTEST!
    }
}

// DOPO (funziona correttamente):
if (tickCounter % 1000 == 0 && !MQLInfoInteger(MQL_TESTER)) {  // Solo in LIVE trading
    long memoryAvailable = memoryLimit - memoryUsed;
    if (memoryAvailable < 50 * 1024 * 1024) {
        return;  // Blocco solo in trading reale se memoria critica
    }
}
```
**Risultato**: Il controllo memoria è **attivo solo in trading reale**, dove `TerminalInfoInteger` funziona correttamente. In backtest non interferisce più.

---

### **Fix 2: Aumenta maxLag Minimo (5 → 12)**
```mql5
// PRIMA:
maxLag = MathMax(5, maxLag);  // Troppo basso per trovare cicli

// DOPO:
maxLag = MathMax(12, maxLag);  // Garantisce almeno 12 lag per ricerca cicli
```
**Risultato**: Anche con poche barre (42), ora `maxLag = 12` invece di 6, raddoppiando le possibilità di trovare decay nell'autocorrelazione.

---

### **Fix 3: Fallback Autocorrelazione Intelligente**
```mql5
// PRIMA (fallback troppo piccolo):
if (naturalPeriod == 0) {
    naturalPeriod = maxLag / 2;  // Se maxLag=6 → periodo=3 (TROPPO PICCOLO!)
}

// DOPO (fallback ragionevole):
if (naturalPeriod == 0) {
    int bootstrapMin = GetBootstrapMinBars();  // ~14-17 barre
    naturalPeriod = MathMax(maxLag / 2, bootstrapMin);  // Usa il maggiore tra i due
    PrintFormat("[NATURAL] TF %s: nessun decay trovato, uso max(maxLag/2, bootstrap)=%d", 
        EnumToString(tf), naturalPeriod);
}
```
**Risultato**: Invece di periodo=3, ora usa **almeno bootstrapMin (~14-17 barre)**, che è statisticamente significativo.

---

## Impatto delle Modifiche 📊

### Prima del Fix:
- ❌ Backtest bloccato ogni 1000 tick (memoria falso positivo)
- ❌ Periodo naturale = 2-3 barre (inutile)
- ❌ maxLag = 5-6 (insufficiente)
- ❌ Sistema in loop bootstrap continuo

### Dopo il Fix:
- ✅ Backtest esegue senza blocchi memoria
- ✅ Periodo naturale >= 12-17 barre (statisticamente valido)
- ✅ maxLag >= 12 (può trovare cicli reali)
- ✅ Sistema può uscire dal bootstrap e funzionare normalmente

---

## Verifica del Fix 🔍

### Test da Eseguire:
1. **Ricompila** l'EA con F7 in MetaEditor
2. **Rilancia il backtest** con le stesse impostazioni
3. **Verifica il log**:
   - ✅ Nessun messaggio `[MEMORY CRITICAL]`
   - ✅ `nessun decay trovato, uso max(maxLag/2, bootstrap)=` con valori >= 12-17
   - ✅ Meno warning `Barre insufficienti`
   - ✅ Il test completa senza interruzioni

### Log Atteso (corretto):
```
[NATURAL] TF PERIOD_M5: Bars()=77327, richiesto=42, minimo=17
[NATURAL] TF PERIOD_M5: nessun decay trovato, uso max(maxLag/2, bootstrap)=17  ← MIGLIORATO!
[NATURAL] TF PERIOD_H1: nessun decay trovato, uso max(maxLag/2, bootstrap)=14  ← MIGLIORATO!
```

---

## Note Tecniche 📝

### Perché il Controllo Memoria Non Funziona in Backtest?
Il **Strategy Tester** di MT5 usa un ambiente virtualizzato dove:
- `TerminalInfoInteger(TERMINAL_MEMORY_USED)` ritorna 0 o valori non validi
- La memoria reale usata dal tester non è accessibile dall'EA
- Il controllo serve solo per **trading live** su VPS con RAM limitata

### Perché maxLag=12 è il Minimo?
Con `maxLag=12`:
- Può cercare cicli da 1 a 12 barre
- Minimo **12 × 5 min = 1 ora** di dati per M5 (ciclo intraday)
- Minimo **12 × 1 ora = 12 ore** di dati per H1 (ciclo giornaliero)
- Statisticamente significativo per autocorrelazione

### Perché Usare bootstrapMin come Fallback?
`bootstrapMin = sqrt(barsAvailable) ≈ 14-17` è il **minimo statistico** per:
- Calcolare varianza con confidenza
- Trovare trend/reversal
- Evitare overfitting su pochi dati

---

## Conclusione ✨

Questi fix risolvono:
1. ✅ **Blocchi memoria falsi** in backtest
2. ✅ **Periodi troppo corti** (3 barre → 14-17 barre minimo)
3. ✅ **maxLag insufficiente** (6 → 12 minimo)
4. ✅ **Loop bootstrap** continuo

**Risultato finale**: L'EA può completare il backtest senza blocchi e usa periodi statisticamente validi per l'analisi.

---

**Data**: 2026-01-11  
**Versione**: EA_ORGANIC_Jarvis_v1.1.mq5  
**Status**: ✅ FIX APPLICATO - Pronto per test
