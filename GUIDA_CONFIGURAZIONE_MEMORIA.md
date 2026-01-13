# Guida Configurazione Memoria - EA Organic Jarvis

## 📊 Nuovi Parametri Configurabili

Ora puoi controllare esattamente quanti giorni di storia usare per ogni timeframe!

### Sezione Input: "CONFIGURAZIONE MEMORIA"

```cpp
WindowDays_M5      = 3    // M5: Giorni storia
WindowDays_H1      = 7    // H1: Giorni storia  
WindowDays_H4      = 14   // H4: Giorni storia
WindowDays_D1      = 30   // D1: Giorni storia
MaxLagFraction     = 0.15 // MaxLag autocorrelazione (% barre)
MaxLagAbsolute     = 150  // MaxLag massimo assoluto
```

---

## 🎯 Valori Consigliati (Default)

### **Per PC Normali** (4GB+ RAM)
| Timeframe | Giorni | Barre ~circa | MaxLag | Memoria |
|-----------|--------|--------------|--------|---------|
| **M5** | 3 | ~864 | ~130 | ~35 MB |
| **H1** | 7 | ~168 | ~25 | ~10 MB |
| **H4** | 14 | ~84 | ~13 | ~5 MB |
| **D1** | 30 | ~30 | ~5 | ~2 MB |
| **TOTALE** | - | - | - | **~52 MB** |

```
WindowDays_M5 = 3
WindowDays_H1 = 7
WindowDays_H4 = 14
WindowDays_D1 = 30
MaxLagFraction = 0.15
MaxLagAbsolute = 150
```

### **Per PC Deboli** (2GB RAM o meno)
| Timeframe | Giorni | Barre | MaxLag | Memoria |
|-----------|--------|-------|--------|---------|
| **M5** | 2 | ~576 | ~60 | ~20 MB |
| **H1** | 5 | ~120 | ~12 | ~6 MB |
| **H4** | 10 | ~60 | ~9 | ~3 MB |
| **D1** | 20 | ~20 | ~5 (min) | ~1 MB |
| **TOTALE** | - | - | - | **~30 MB** |

```
WindowDays_M5 = 2
WindowDays_H1 = 5
WindowDays_H4 = 10
WindowDays_D1 = 20
MaxLagFraction = 0.10
MaxLagAbsolute = 100
```

### **Per Trading Aggressivo** (reattività massima)
| Timeframe | Giorni | Barre | MaxLag | Note |
|-----------|--------|-------|--------|------|
| **M5** | 1-2 | ~288-576 | ~30-60 | Solo dati ultra-recenti |
| **H1** | 3-5 | ~72-120 | ~10-15 | Focus intraday |
| **H4** | 7-10 | ~42-60 | ~6-9 | Trend rapido |
| **D1** | 14-20 | ~14-20 | ~5 | Contesto generale |

```
WindowDays_M5 = 1
WindowDays_H1 = 3
WindowDays_H4 = 7
WindowDays_D1 = 14
MaxLagFraction = 0.10
MaxLagAbsolute = 80
```

### **Per Trading Conservativo** (statistiche robuste)
| Timeframe | Giorni | Barre | MaxLag | Note |
|-----------|--------|-------|--------|------|
| **M5** | 5-7 | ~1440-2016 | ~200+ | Max statistiche M5 |
| **H1** | 14-21 | ~336-504 | ~50-75 | Trend robusto |
| **H4** | 30-60 | ~180-360 | ~30-50 | Swing trading |
| **D1** | 60-90 | ~60-90 | ~10-15 | Position trading |

```
WindowDays_M5 = 5
WindowDays_H1 = 14
WindowDays_H4 = 30
WindowDays_D1 = 60
MaxLagFraction = 0.15
MaxLagAbsolute = 200
```

---

## ⚙️ Spiegazione Parametri

### **WindowDays_XX** (Giorni Storia)
- **Cosa fa**: Quanti giorni di storia caricare per quel TF
- **Più alto** = statistiche più robuste, ma più memoria/CPU
- **Più basso** = più reattivo, ma meno dati storici

**Formula barre**: `Giorni × 24 × 60 / MinutiPerBarra`
- M5: 3 giorni = 3 × 24 × 60 / 5 = **864 barre**
- H1: 7 giorni = 7 × 24 × 60 / 60 = **168 barre**
- H4: 14 giorni = 14 × 24 / 4 = **84 barre**
- D1: 30 giorni = **30 barre**

### **MaxLagFraction** (Frazione MaxLag)
- **Cosa fa**: Percentuale delle barre da usare per cercare cicli (autocorrelazione)
- **Default**: 0.15 (15% delle barre)
- **Range sicuro**: 0.10 - 0.20

**Esempio**: 
- M5 con 864 barre e 0.15 → MaxLag = 864 × 0.15 = **~130 lag**
- Più alto = cerca cicli più lunghi (più lento)
- Più basso = cerca solo cicli brevi (più veloce)

### **MaxLagAbsolute** (Limite Assoluto)
- **Cosa fa**: Limita il maxLag anche se la frazione è alta
- **Default**: 150 lag
- **Perché serve**: Evita che D1 con 90 barre faccia 90×0.15=13 lag (troppo pochi!)

**Safety**: 
- Minimo: 5 lag (sempre garantito)
- Massimo: MaxLagAbsolute (tetto tecnico)

---

## 💾 Calcolo Memoria Approssimativo

**Formula per TF**:
```
Memoria_TF ≈ Barre × 20_indicatori × 8_bytes_double / 1024 / 1024
           ≈ Barre × 0.00015 MB
```

**Esempi**:
- M5 (864 barre): 864 × 0.00015 = **~0.13 MB per indicatore** × 20 = ~2.6 MB
- Ma con buffer + autocorrelazione → **×10-15 fattore moltiplicativo**
- **M5 reale**: ~35 MB, **H1**: ~10 MB, **H4**: ~5 MB, **D1**: ~2 MB

---

## 🚦 Come Scegliere i Valori Giusti

### 1️⃣ **Guarda il Log all'Avvio**

Quando avvii l'EA, vedrai:
```
CONFIGURAZIONE MEMORIA (Giorni Storia per Timeframe):
  M5:  3 giorni = ~864 barre (maxLag=129)
  H1:  7 giorni = ~168 barre (maxLag=25)
  H4:  14 giorni = ~84 barre (maxLag=12)
  D1:  30 giorni = ~30 barre (maxLag=5)
  MaxLag: 15.0% barre (max assoluto=150)
```

### 2️⃣ **Monitora Task Manager**

Dopo 5-10 minuti di esecuzione:
- **MT5 usa <200 MB**: Puoi aumentare i giorni
- **MT5 usa 200-400 MB**: Perfetto, valori ottimali
- **MT5 usa >500 MB**: Riduci giorni o disabilita TF pesanti

### 3️⃣ **Osserva Performance**

- **EA lento/lag**: Riduci `MaxLagFraction` o `WindowDays_M5`
- **Troppi "dati insufficienti"**: Aumenta giorni per quei TF
- **PC si blocca**: Disabilita D1 e riduci tutti i giorni del 50%

---

## 🎛️ Regolazioni Fine

### Se vuoi **MASSIMA PERFORMANCE**:
1. Usa solo M5 e H1 (disabilita H4/D1)
2. Riduci M5 a 2 giorni
3. MaxLagFraction = 0.10
4. MaxLagAbsolute = 80

### Se vuoi **MASSIMA ROBUSTEZZA**:
1. Aumenta tutti i giorni (×2)
2. MaxLagFraction = 0.20
3. MaxLagAbsolute = 200
4. Serve PC potente (8GB+ RAM)

### Se il **PC CRASHA ANCORA**:
1. **Disabilita D1** (input `EnableVote_D1 = false`)
2. WindowDays_M5 = 1
3. WindowDays_H1 = 3
4. WindowDays_H4 = 7
5. MaxLagFraction = 0.08
6. MaxLagAbsolute = 50

---

## ✅ Configurazione Finale Consigliata

**Per la maggior parte degli utenti (bilanciata)**:
```
WindowDays_M5 = 3
WindowDays_H1 = 7
WindowDays_H4 = 14
WindowDays_D1 = 30
MaxLagFraction = 0.15
MaxLagAbsolute = 150
```

**Memoria stimata**: ~50-60 MB
**Performance**: Ottima
**Robustezza**: Eccellente

---

## 📈 Hard Cap Automatici (Protezione)

Anche se imposti valori altissimi, l'EA ha **limiti di sicurezza**:

| Timeframe | Hard Cap Barre | Motivo |
|-----------|----------------|--------|
| M5, M15 | 2000 | TF piccoli gestiscono più dati |
| H1 | 500 | Bilanciamento memoria/dati |
| H4 | 200 | TF grandi pesano di più |
| D1, W1 | 50 | Una barra = un giorno intero! |

**Non puoi superare questi limiti** anche se metti 365 giorni!

---

**Data**: 11 Gennaio 2026
**Versione**: 1.1 - Sistema Proporzionale Configurabile
