# -*- coding: utf-8 -*-
"""
Esempio di utilizzo del Monte Carlo Analyzer
=============================================
Script di esempio per analizzare i backtest di EA_ORGANIC_Jarvis.

PERCORSI FILE ESPORTATI DA MT5:
- BACKTEST: C:\\Users\\[User]\\AppData\\Roaming\\MetaQuotes\\Terminal\\Common\\Files\\
- LIVE:     C:\\Users\\[User]\\AppData\\Roaming\\MetaQuotes\\Terminal\\[ID]\\MQL5\\Files\\

Nome file: trades_SIMBOLO_DATA_backtest.csv (o _live.csv)
"""

from montecarlo_analyzer import MonteCarloAnalyzer, create_sample_trades, load_mt5_report
from pathlib import Path
import os
import glob


def find_latest_trades_file():
    """Cerca automaticamente il file trades più recente nella cartella Common di MT5."""
    # Percorso comune MT5
    common_paths = [
        os.path.expanduser("~") + "\\AppData\\Roaming\\MetaQuotes\\Terminal\\Common\\Files",
        "C:\\Users\\Public\\Documents\\MetaQuotes\\Terminal\\Common\\Files",
    ]
    
    all_files = []
    
    for base_path in common_paths:
        if os.path.exists(base_path):
            # Cerca sia file backtest che live
            for pattern_suffix in ["_backtest.csv", "_live.csv"]:
                pattern = os.path.join(base_path, f"trades_*{pattern_suffix}")
                files = glob.glob(pattern)
                all_files.extend(files)
    
    if all_files:
        # Ritorna il file più recente tra tutti
        latest = max(all_files, key=os.path.getmtime)
        return latest
    
    return None


def main():
    """Funzione principale di esempio."""
    
    print("\n" + "="*60)
    print("  MONTE CARLO ANALYZER - EA ORGANIC JARVIS")
    print("="*60)
    
    # =========================================================================
    # CERCA AUTOMATICAMENTE FILE BACKTEST
    # =========================================================================
    latest_file = find_latest_trades_file()
    
    if latest_file:
        print(f"\n📂 Trovato file backtest: {latest_file}")
        print("   Vuoi usare questo file? (premi Invio per sì, 'n' per usare demo)")
        choice = input("   > ").strip().lower()
        
        if choice != 'n':
            print(f"\n📌 ANALISI FILE BACKTEST: {Path(latest_file).name}\n")
            
            try:
                # Carica il file
                trades_df = load_mt5_report(latest_file)
                
                # Usa balance iniziale dal file se disponibile, altrimenti default
                initial_balance = trades_df.attrs.get('initial_balance', 10000)
                
                # Crea l'analizzatore
                analyzer = MonteCarloAnalyzer(
                    trades=trades_df,
                    initial_balance=initial_balance,
                    num_simulations=1000,
                    confidence_level=0.95
                )
                
                # Esegui e mostra risultati
                analyzer.run_simulation()
                analyzer.print_report()
                
                # Genera grafici
                output_dir = Path("output")
                output_dir.mkdir(exist_ok=True)
                
                analyzer.plot_equity_curves(save_path=str(output_dir / "equity_curves.png"))
                analyzer.plot_distribution(save_path=str(output_dir / "distribution.png"))
                analyzer.plot_risk_analysis(save_path=str(output_dir / "risk_analysis.png"))
                analyzer.export_results(str(output_dir / "montecarlo_results.csv"))
                
                print("\n✅ Analisi completata! Grafici salvati in 'output/'")
                return
                
            except Exception as e:
                print(f"\n❌ Errore durante l'analisi: {e}")
                print("   Provo con i dati demo...\n")
    
    # =========================================================================
    # ESEMPIO CON TRADE SIMULATI (demo)
    # =========================================================================
    print("\n📌 DEMO: Analisi con trade simulati\n")
    print("   (Per analizzare un backtest reale, esporta prima i trade da MT5)")
    
    # Simula i risultati di un backtest
    sample_trades = create_sample_trades(
        n_trades=250,        # Numero di trade nel backtest
        win_rate=0.57,       # Win rate (57%)
        avg_win=100,         # Vincita media in $
        avg_loss=-75,        # Perdita media in $
        seed=123             # Per riproducibilità
    )
    
    # Crea l'analizzatore
    analyzer = MonteCarloAnalyzer(
        trades=sample_trades,
        initial_balance=10000,    # Capitale iniziale
        num_simulations=1000,     # Numero simulazioni
        confidence_level=0.95     # Livello confidenza 95%
    )
    
    # Esegui simulazione
    analyzer.run_simulation()
    
    # Stampa report completo
    analyzer.print_report()
    
    # Genera grafici (salva automaticamente come PNG)
    output_dir = Path("output")
    output_dir.mkdir(exist_ok=True)
    
    analyzer.plot_equity_curves(
        num_curves=100,
        save_path=str(output_dir / "equity_curves.png")
    )
    
    analyzer.plot_distribution(
        save_path=str(output_dir / "distribution.png")
    )
    
    analyzer.plot_risk_analysis(
        save_path=str(output_dir / "risk_analysis.png")
    )
    
    # Esporta risultati in CSV
    analyzer.export_results(str(output_dir / "montecarlo_results.csv"))
    
    # =========================================================================
    # ESEMPIO 2: Carica da file CSV (decommentare per usare)
    # =========================================================================
    """
    print("\n📌 ESEMPIO 2: Analisi da report CSV\n")
    
    # Formato CSV atteso:
    # Time,Type,Volume,Price,Profit,Balance
    # 2024.01.01,Buy,0.1,1.0950,50.00,10050.00
    # ...
    
    trades_df = load_mt5_report('path/to/your/backtest_report.csv')
    
    analyzer = MonteCarloAnalyzer(
        trades=trades_df,
        initial_balance=10000,
        num_simulations=1000
    )
    
    analyzer.run_simulation()
    analyzer.print_report()
    analyzer.plot_equity_curves()
    """
    
    print("\n" + "="*60)
    print("  ✅ ANALISI COMPLETATA!")
    print("="*60)
    print("\n📁 I risultati sono stati salvati nella cartella 'output/'")
    print("   - equity_curves.png")
    print("   - distribution.png")
    print("   - risk_analysis.png")
    print("   - montecarlo_results.csv")
    print("   - montecarlo_results_statistics.csv")
    print("\n💡 Per analizzare un backtest reale:")
    print("   1. Esegui il backtest in MT5 con ExportTradesCSV=true")
    print("   2. Il file viene salvato automaticamente in:")
    print("      C:\\Users\\[User]\\AppData\\Roaming\\MetaQuotes\\Terminal\\Common\\Files\\")
    print("   3. Riesegui questo script - troverà automaticamente il file!\n")


if __name__ == "__main__":
    main()