# 🎲 Monte Carlo Analyzer - EA ORGANIC Jarvis

Strumento di analisi Monte Carlo per valutare la robustezza dei risultati dei backtest dell'EA ORGANIC Jarvis.

## 📋 Descrizione

L'analisi Monte Carlo è una tecnica statistica che permette di:
- Valutare la **robustezza** di una strategia di trading
- Stimare la **distribuzione probabilistica** dei risultati futuri
- Calcolare il **rischio di rovina** e le probabilità di profitto
- Identificare i **drawdown potenziali** in scenari avversi

## 🚀 Installazione

### Prerequisiti
- Python 3.9 o superiore
- pip (gestore pacchetti Python)

### Setup

```bash
# Naviga nella cartella montecarlo
cd montecarlo

# Installa le dipendenze
pip install -r requirements.txt
```

## � Dove Trovare i File dei Trade

### L'EA esporta automaticamente!
EA_ORGANIC_Jarvis esporta i trade in CSV alla fine di ogni backtest/sessione.

**Percorso file esportato:**
```
C:\Users\[TuoUtente]\AppData\Roaming\MetaQuotes\Terminal\[ID]\MQL5\Files\
```

Il file si chiama: `trades_SIMBOLO_DATA.csv`

Esempio: `trades_EURUSD_2024-12-28.csv`

### Come attivare l'export:
1. Nelle impostazioni EA, assicurati che `ExportTradesCSV = true`
2. Esegui il backtest
3. Alla fine, il file viene creato automaticamente

## �📊 Utilizzo

### 1. Utilizzo Base (con trade di esempio)

```python
from montecarlo_analyzer import MonteCarloAnalyzer, create_sample_trades

# Crea trade di esempio
trades = create_sample_trades(n_trades=200, win_rate=0.55)

# Crea l'analizzatore
analyzer = MonteCarloAnalyzer(
    trades=trades,
    initial_balance=10000,
    num_simulations=1000
)

# Esegui e visualizza
analyzer.run_simulation()
analyzer.print_report()
analyzer.plot_equity_curves()
```

### 2. Caricamento da Report MT5

```python
from montecarlo_analyzer import MonteCarloAnalyzer, load_mt5_report

# Carica report backtest da CSV
trades_df = load_mt5_report('backtest_report.csv')

# Analizza
analyzer = MonteCarloAnalyzer(trades=trades_df, initial_balance=10000)
analyzer.run_simulation()
analyzer.print_report()
```

### 3. Da Lista di Profitti/Perdite

```python
# Lista dei P/L per ogni trade
my_trades = [50, -30, 80, -20, 100, -40, 60, ...]

analyzer = MonteCarloAnalyzer(trades=my_trades, initial_balance=10000)
analyzer.run_simulation()
analyzer.print_report()
```

## 📈 Output

### Report Testuale
Il report include:
- **Statistiche Backtest Originale**: trade totali, win rate, profit factor, max DD
- **Risultati Monte Carlo**: media, mediana, min/max balance
- **Distribuzione Percentili**: 5°, 25°, 50°, 75°, 95° percentile
- **Analisi Rischio**: probabilità profitto, probabilità rovina, VaR, CVaR

### Grafici
1. **Curve Equity**: visualizza centinaia di possibili percorsi equity
2. **Distribuzione Balance**: istogramma e box plot del balance finale
3. **Analisi Rischio**: metriche di rischio e durata drawdown

### Export CSV
```python
analyzer.export_results('risultati_montecarlo.csv')
```

## 🔧 Parametri Configurabili

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| `trades` | - | DataFrame o lista di P/L |
| `initial_balance` | 10000 | Capitale iniziale |
| `num_simulations` | 1000 | Numero simulazioni MC |
| `confidence_level` | 0.95 | Livello di confidenza |

## 📐 Metriche Calcolate

### Statistiche Base
- **Win Rate**: percentuale trade vincenti
- **Profit Factor**: rapporto profitti lordi / perdite lorde
- **Sharpe Ratio**: rendimento risk-adjusted annualizzato

### Metriche Monte Carlo
- **VaR (Value at Risk)**: perdita massima al 95% confidenza
- **CVaR (Expected Shortfall)**: perdita media oltre il VaR
- **Probabilità di Rovina**: % simulazioni con balance < 50% iniziale
- **Distribuzione Drawdown**: analisi completa dei drawdown

## 📁 Struttura File

```
montecarlo/
├── montecarlo_analyzer.py   # Script principale
├── requirements.txt          # Dipendenze Python
├── README.md                 # Questa guida
└── output/                   # (creata automaticamente)
    ├── equity_curves.png
    ├── distribution.png
    ├── risk_analysis.png
    └── montecarlo_results.csv
```

## 💡 Best Practices

1. **Numero Simulazioni**: usa almeno 1000 simulazioni per risultati stabili
2. **Sample Size**: più trade nel backtest = risultati più affidabili
3. **Interpretazione**:
   - Probabilità profitto > 90% = eccellente
   - Probabilità rovina < 1% = molto sicuro
   - DD 95° percentile < 25% = rischio controllato

## ⚠️ Limitazioni

- I risultati Monte Carlo assumono che i trade siano **indipendenti**
- Non considera costi di slippage, spread variabili
- I risultati passati non garantiscono performance future

## 📞 Supporto

Per domande o problemi, consulta la documentazione dell'EA ORGANIC Jarvis.

---
*Organic Jarvis Team - 2025*
