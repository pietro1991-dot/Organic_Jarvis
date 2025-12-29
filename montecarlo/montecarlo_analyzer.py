# -*- coding: utf-8 -*-
"""
Monte Carlo Analyzer for EA Backtest Results
=============================================
Analizza i risultati dei backtest di EA_ORGANIC_Jarvis usando simulazioni Monte Carlo.

Autore: Organic Jarvis Team
Versione: 1.0.0
"""

import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import seaborn as sns
from scipy import stats
from pathlib import Path
from typing import Tuple, List, Optional, Union
import warnings
warnings.filterwarnings('ignore')

# Configurazione stile grafici
plt.style.use('seaborn-v0_8-darkgrid')
sns.set_palette("husl")


def safe_numeric(value) -> float:
    """
    Converte un valore in numero gestendo sia virgola che punto come decimale.
    Gestisce anche stringhe malformate.
    """
    if pd.isna(value):
        return np.nan
    if isinstance(value, (int, float)):
        return float(value)
    
    # Converti in stringa e pulisci
    s = str(value).strip()
    if not s:
        return np.nan
    
    # Se contiene sia virgola che punto, il punto è separatore migliaia
    if ',' in s and '.' in s:
        # Determina quale è il decimale (l'ultimo separatore)
        last_comma = s.rfind(',')
        last_dot = s.rfind('.')
        if last_comma > last_dot:
            # Virgola è decimale (formato europeo: 1.234,56)
            s = s.replace('.', '').replace(',', '.')
        else:
            # Punto è decimale (formato USA: 1,234.56)
            s = s.replace(',', '')
    elif ',' in s:
        # Solo virgola - potrebbe essere decimale
        s = s.replace(',', '.')
    
    try:
        return float(s)
    except ValueError:
        return np.nan


class MonteCarloAnalyzer:
    """
    Classe per l'analisi Monte Carlo dei risultati di backtest.
    
    Parametri:
    ----------
    trades : pd.DataFrame o list
        DataFrame con colonna 'profit' o lista di profitti/perdite per trade
    initial_balance : float
        Capitale iniziale (default: 10000)
    num_simulations : int
        Numero di simulazioni Monte Carlo (default: 1000)
    confidence_level : float
        Livello di confidenza per le statistiche (default: 0.95)
    """
    
    def __init__(self, 
                 trades: pd.DataFrame | list,
                 initial_balance: float = 10000,
                 num_simulations: int = 1000,
                 confidence_level: float = 0.95):
        
        # Converti trades in array numpy (assicura tipo float64)
        if isinstance(trades, pd.DataFrame):
            if 'profit' in trades.columns:
                self.trades: np.ndarray = np.array(trades['profit'].values, dtype=np.float64)
            elif 'Profit' in trades.columns:
                self.trades: np.ndarray = np.array(trades['Profit'].values, dtype=np.float64)
            else:
                raise ValueError("DataFrame deve contenere colonna 'profit' o 'Profit'")
        elif isinstance(trades, list):
            self.trades: np.ndarray = np.array(trades, dtype=np.float64)
        else:
            self.trades: np.ndarray = np.array(trades, dtype=np.float64)
        
        self.initial_balance: float = initial_balance
        self.num_simulations: int = num_simulations
        self.confidence_level: float = confidence_level
        
        # Risultati delle simulazioni (inizializzati in run_simulation)
        self.equity_curves: np.ndarray = np.array([])
        self.final_balances: np.ndarray = np.array([])
        self.max_drawdowns: np.ndarray = np.array([])
        self.max_drawdown_durations: np.ndarray = np.array([])
        
        # Statistiche originali
        self.original_stats = self._calculate_original_stats()
    
    def _calculate_original_stats(self) -> dict:
        """Calcola le statistiche del backtest originale."""
        equity_curve = self.initial_balance + np.cumsum(self.trades)
        
        # Drawdown calculation
        running_max = np.maximum.accumulate(equity_curve)
        drawdown = (running_max - equity_curve) / running_max * 100
        max_dd = np.max(drawdown)
        
        # Win rate
        wins = np.sum(self.trades > 0)
        losses = np.sum(self.trades < 0)
        total_trades = len(self.trades)
        win_rate = wins / total_trades * 100 if total_trades > 0 else 0
        
        # Profit factor
        gross_profit = np.sum(self.trades[self.trades > 0])
        gross_loss = abs(np.sum(self.trades[self.trades < 0]))
        profit_factor = gross_profit / gross_loss if gross_loss > 0 else float('inf')
        
        # Average win/loss
        avg_win = np.mean(self.trades[self.trades > 0]) if wins > 0 else 0
        avg_loss = np.mean(self.trades[self.trades < 0]) if losses > 0 else 0
        
        # Sharpe ratio (annualizzato, assumendo 252 giorni di trading)
        if np.std(self.trades) > 0:
            sharpe = np.mean(self.trades) / np.std(self.trades) * np.sqrt(252)
        else:
            sharpe = 0
        
        return {
            'total_trades': total_trades,
            'total_profit': np.sum(self.trades),
            'final_balance': equity_curve[-1],
            'win_rate': win_rate,
            'profit_factor': profit_factor,
            'max_drawdown': max_dd,
            'avg_win': avg_win,
            'avg_loss': avg_loss,
            'sharpe_ratio': sharpe,
            'equity_curve': equity_curve
        }
    
    def run_simulation(self) -> None:
        """Esegue le simulazioni Monte Carlo."""
        print(f"🎲 Esecuzione di {self.num_simulations} simulazioni Monte Carlo...")
        
        n_trades = len(self.trades)
        self.equity_curves = np.zeros((self.num_simulations, n_trades + 1))
        self.final_balances = np.zeros(self.num_simulations)
        self.max_drawdowns = np.zeros(self.num_simulations)
        self.max_drawdown_durations = np.zeros(self.num_simulations)
        
        for i in range(self.num_simulations):
            # Ricampiona i trade con rimpiazzamento (bootstrap)
            resampled_trades = np.random.choice(self.trades, size=n_trades, replace=True)
            
            # Calcola curva equity
            equity = np.zeros(n_trades + 1)
            equity[0] = self.initial_balance
            equity[1:] = self.initial_balance + np.cumsum(resampled_trades)
            
            self.equity_curves[i] = equity
            self.final_balances[i] = equity[-1]
            
            # Calcola max drawdown
            running_max = np.maximum.accumulate(equity)
            drawdown = (running_max - equity) / running_max * 100
            self.max_drawdowns[i] = np.max(drawdown)
            
            # Calcola durata max drawdown
            in_drawdown = drawdown > 0
            dd_duration = 0
            max_duration = 0
            for dd in in_drawdown:
                if dd:
                    dd_duration += 1
                    max_duration = max(max_duration, dd_duration)
                else:
                    dd_duration = 0
            self.max_drawdown_durations[i] = max_duration
        
        print("✅ Simulazione completata!")
    
    def get_statistics(self) -> dict:
        """Calcola le statistiche delle simulazioni Monte Carlo."""
        if len(self.final_balances) == 0:
            self.run_simulation()
        
        alpha = 1 - self.confidence_level
        
        # Calcola percentili
        balance_percentiles = np.percentile(self.final_balances, [5, 25, 50, 75, 95])
        dd_percentiles = np.percentile(self.max_drawdowns, [5, 25, 50, 75, 95])
        
        # Probabilità di rovina (balance < 50% del capitale iniziale)
        ruin_threshold = self.initial_balance * 0.5
        prob_ruin = float(np.mean(self.final_balances < ruin_threshold) * 100)
        
        # Probabilità di profitto
        prob_profit = float(np.mean(self.final_balances > self.initial_balance) * 100)
        
        # Value at Risk (VaR) al 95%
        var_95 = float(np.percentile(self.final_balances - self.initial_balance, 5))
        
        # Expected Shortfall (CVaR)
        losses = self.final_balances - self.initial_balance
        cvar_95 = float(np.mean(losses[losses <= np.percentile(losses, 5)]))
        
        return {
            'mean_final_balance': np.mean(self.final_balances),
            'std_final_balance': np.std(self.final_balances),
            'median_final_balance': np.median(self.final_balances),
            'min_final_balance': np.min(self.final_balances),
            'max_final_balance': np.max(self.final_balances),
            'balance_5th_percentile': balance_percentiles[0],
            'balance_25th_percentile': balance_percentiles[1],
            'balance_50th_percentile': balance_percentiles[2],
            'balance_75th_percentile': balance_percentiles[3],
            'balance_95th_percentile': balance_percentiles[4],
            'mean_max_drawdown': np.mean(self.max_drawdowns),
            'worst_max_drawdown': np.max(self.max_drawdowns),
            'dd_5th_percentile': dd_percentiles[0],
            'dd_95th_percentile': dd_percentiles[4],
            'mean_dd_duration': np.mean(self.max_drawdown_durations),
            'max_dd_duration': np.max(self.max_drawdown_durations),
            'probability_of_profit': prob_profit,
            'probability_of_ruin': prob_ruin,
            'var_95': var_95,
            'cvar_95': cvar_95
        }
    
    def print_report(self) -> None:
        """Stampa un report completo delle analisi."""
        stats = self.get_statistics()
        orig = self.original_stats
        
        print("\n" + "="*70)
        print("📊 MONTE CARLO ANALYSIS REPORT - EA ORGANIC JARVIS")
        print("="*70)
        
        print("\n📈 STATISTICHE BACKTEST ORIGINALE:")
        print("-"*40)
        print(f"  Numero Trade:        {orig['total_trades']}")
        print(f"  Profitto Totale:     ${orig['total_profit']:,.2f}")
        print(f"  Balance Finale:      ${orig['final_balance']:,.2f}")
        print(f"  Win Rate:            {orig['win_rate']:.1f}%")
        print(f"  Profit Factor:       {orig['profit_factor']:.2f}")
        print(f"  Max Drawdown:        {orig['max_drawdown']:.2f}%")
        print(f"  Media Vincite:       ${orig['avg_win']:,.2f}")
        print(f"  Media Perdite:       ${orig['avg_loss']:,.2f}")
        print(f"  Sharpe Ratio:        {orig['sharpe_ratio']:.2f}")
        
        print(f"\n🎲 RISULTATI MONTE CARLO ({self.num_simulations} simulazioni):")
        print("-"*40)
        print(f"  Balance Finale Medio:    ${stats['mean_final_balance']:,.2f}")
        print(f"  Deviazione Standard:     ${stats['std_final_balance']:,.2f}")
        print(f"  Balance Minimo:          ${stats['min_final_balance']:,.2f}")
        print(f"  Balance Massimo:         ${stats['max_final_balance']:,.2f}")
        
        print(f"\n📊 DISTRIBUZIONE BALANCE FINALE:")
        print("-"*40)
        print(f"   5° Percentile:      ${stats['balance_5th_percentile']:,.2f}")
        print(f"  25° Percentile:      ${stats['balance_25th_percentile']:,.2f}")
        print(f"  50° Percentile:      ${stats['balance_50th_percentile']:,.2f}")
        print(f"  75° Percentile:      ${stats['balance_75th_percentile']:,.2f}")
        print(f"  95° Percentile:      ${stats['balance_95th_percentile']:,.2f}")
        
        print(f"\n📉 ANALISI DRAWDOWN:")
        print("-"*40)
        print(f"  Max DD Medio:        {stats['mean_max_drawdown']:.2f}%")
        print(f"  Max DD Peggiore:     {stats['worst_max_drawdown']:.2f}%")
        print(f"  DD 95° Percentile:   {stats['dd_95th_percentile']:.2f}%")
        print(f"  Durata DD Media:     {stats['mean_dd_duration']:.0f} trade")
        print(f"  Durata DD Massima:   {stats['max_dd_duration']:.0f} trade")
        
        print(f"\n⚠️  ANALISI RISCHIO:")
        print("-"*40)
        print(f"  Probabilità Profitto:  {stats['probability_of_profit']:.1f}%")
        print(f"  Probabilità Rovina:    {stats['probability_of_ruin']:.1f}%")
        print(f"  VaR (95%):             ${stats['var_95']:,.2f}")
        print(f"  CVaR (95%):            ${stats['cvar_95']:,.2f}")
        
        print("\n" + "="*70)
        print("💡 INTERPRETAZIONE:")
        print("-"*40)
        
        if stats['probability_of_profit'] >= 90:
            print("  ✅ Alta probabilità di profitto (>90%)")
        elif stats['probability_of_profit'] >= 70:
            print("  ⚠️  Buona probabilità di profitto (70-90%)")
        else:
            print("  ❌ Bassa probabilità di profitto (<70%)")
        
        if stats['probability_of_ruin'] <= 1:
            print("  ✅ Rischio di rovina molto basso (<1%)")
        elif stats['probability_of_ruin'] <= 5:
            print("  ⚠️  Rischio di rovina accettabile (1-5%)")
        else:
            print("  ❌ Rischio di rovina elevato (>5%)")
        
        if stats['dd_95th_percentile'] <= 20:
            print("  ✅ Drawdown ben controllato (<20%)")
        elif stats['dd_95th_percentile'] <= 30:
            print("  ⚠️  Drawdown moderato (20-30%)")
        else:
            print("  ❌ Drawdown elevato (>30%)")
        
        print("="*70 + "\n")
    
    def plot_equity_curves(self, 
                           num_curves: int = 100,
                           show_percentiles: bool = True,
                           save_path: Optional[str] = None) -> None:
        """
        Visualizza le curve equity delle simulazioni.
        
        Parametri:
        ----------
        num_curves : int
            Numero di curve da visualizzare (default: 100)
        show_percentiles : bool
            Mostra le bande di percentile (default: True)
        save_path : str, optional
            Percorso per salvare il grafico
        """
        if len(self.equity_curves) == 0:
            self.run_simulation()
        
        fig, ax = plt.subplots(figsize=(14, 8))
        
        # Plot sample curves
        sample_indices = np.random.choice(self.num_simulations, 
                                          min(num_curves, self.num_simulations), 
                                          replace=False)
        
        for i in sample_indices:
            ax.plot(self.equity_curves[i], alpha=0.1, color='blue', linewidth=0.5)
        
        # Plot percentiles
        if show_percentiles:
            percentiles = [5, 25, 50, 75, 95]
            colors = ['red', 'orange', 'green', 'orange', 'red']
            labels = ['5° percentile', '25° percentile', 'Mediana', 
                     '75° percentile', '95° percentile']
            linestyles = ['--', '-.', '-', '-.', '--']
            
            for p, c, l, ls in zip(percentiles, colors, labels, linestyles):
                percentile_curve = np.percentile(self.equity_curves, p, axis=0)
                ax.plot(percentile_curve, color=c, linewidth=2, 
                       linestyle=ls, label=l)
        
        # Plot original equity curve
        original_equity = np.concatenate([[self.initial_balance], 
                                          self.original_stats['equity_curve']])
        ax.plot(original_equity, color='black', linewidth=2.5, 
               label='Backtest Originale', linestyle='-')
        
        ax.axhline(y=self.initial_balance, color='gray', linestyle=':', 
                  alpha=0.7, label='Capitale Iniziale')
        
        ax.set_xlabel('Numero Trade', fontsize=12)
        ax.set_ylabel('Equity ($)', fontsize=12)
        ax.set_title('Monte Carlo Simulation - Curve Equity\n'
                    f'({self.num_simulations} simulazioni)', fontsize=14, fontweight='bold')
        ax.legend(loc='upper left', fontsize=10)
        ax.grid(True, alpha=0.3)
        
        # Format y-axis
        ax.yaxis.set_major_formatter(FuncFormatter(lambda x, p: f'${x:,.0f}'))
        
        plt.tight_layout()
        
        if save_path:
            plt.savefig(save_path, dpi=300, bbox_inches='tight')
            print(f"📊 Grafico salvato in: {save_path}")
        
        plt.show()
    
    def plot_distribution(self, save_path: Optional[str] = None) -> None:
        """
        Visualizza la distribuzione dei risultati Monte Carlo.
        
        Parametri:
        ----------
        save_path : str, optional
            Percorso per salvare il grafico
        """
        if len(self.final_balances) == 0:
            self.run_simulation()
        
        fig, axes = plt.subplots(2, 2, figsize=(14, 10))
        
        # 1. Distribuzione Balance Finale
        ax1 = axes[0, 0]
        sns.histplot(self.final_balances, bins=50, kde=True, ax=ax1, color='steelblue')
        ax1.axvline(self.initial_balance, color='red', linestyle='--', 
                   linewidth=2, label='Capitale Iniziale')
        ax1.axvline(self.original_stats['final_balance'], color='green', 
                   linestyle='-', linewidth=2, label='Backtest Originale')
        ax1.axvline(np.mean(self.final_balances), color='orange', 
                   linestyle='-.', linewidth=2, label='Media MC')
        ax1.set_xlabel('Balance Finale ($)', fontsize=11)
        ax1.set_ylabel('Frequenza', fontsize=11)
        ax1.set_title('Distribuzione Balance Finale', fontsize=12, fontweight='bold')
        ax1.legend(fontsize=9)
        ax1.xaxis.set_major_formatter(FuncFormatter(lambda x, p: f'${x:,.0f}'))
        
        # 2. Distribuzione Max Drawdown
        ax2 = axes[0, 1]
        sns.histplot(self.max_drawdowns, bins=50, kde=True, ax=ax2, color='coral')
        ax2.axvline(self.original_stats['max_drawdown'], color='green', 
                   linestyle='-', linewidth=2, label='Backtest Originale')
        ax2.axvline(np.mean(self.max_drawdowns), color='orange', 
                   linestyle='-.', linewidth=2, label='Media MC')
        ax2.axvline(np.percentile(self.max_drawdowns, 95), color='red', 
                   linestyle='--', linewidth=2, label='95° Percentile')
        ax2.set_xlabel('Max Drawdown (%)', fontsize=11)
        ax2.set_ylabel('Frequenza', fontsize=11)
        ax2.set_title('Distribuzione Maximum Drawdown', fontsize=12, fontweight='bold')
        ax2.legend(fontsize=9)
        
        # 3. Box Plot Balance
        ax3 = axes[1, 0]
        bp = ax3.boxplot([self.final_balances], vert=True, patch_artist=True)
        bp['boxes'][0].set_facecolor('lightblue')
        ax3.axhline(self.initial_balance, color='red', linestyle='--', 
                   linewidth=2, label='Capitale Iniziale')
        ax3.axhline(self.original_stats['final_balance'], color='green', 
                   linestyle='-', linewidth=2, label='Backtest Originale')
        ax3.set_ylabel('Balance Finale ($)', fontsize=11)
        ax3.set_title('Box Plot Balance Finale', fontsize=12, fontweight='bold')
        ax3.legend(fontsize=9)
        ax3.yaxis.set_major_formatter(FuncFormatter(lambda x, p: f'${x:,.0f}'))
        ax3.set_xticklabels(['Monte Carlo'])
        
        # 4. Probabilità cumulativa
        ax4 = axes[1, 1]
        sorted_balances = np.sort(self.final_balances)
        cumulative = np.arange(1, len(sorted_balances) + 1) / len(sorted_balances)
        ax4.plot(sorted_balances, cumulative, color='steelblue', linewidth=2)
        ax4.axvline(self.initial_balance, color='red', linestyle='--', 
                   linewidth=2, label='Capitale Iniziale')
        ax4.axhline(0.5, color='gray', linestyle=':', alpha=0.7)
        ax4.fill_between(sorted_balances, 0, cumulative, alpha=0.3)
        ax4.set_xlabel('Balance Finale ($)', fontsize=11)
        ax4.set_ylabel('Probabilità Cumulativa', fontsize=11)
        ax4.set_title('Distribuzione Cumulativa', fontsize=12, fontweight='bold')
        ax4.legend(fontsize=9)
        ax4.xaxis.set_major_formatter(FuncFormatter(lambda x, p: f'${x:,.0f}'))
        ax4.grid(True, alpha=0.3)
        
        plt.suptitle('Analisi Monte Carlo - Distribuzione Risultati\n'
                    f'({self.num_simulations} simulazioni)', 
                    fontsize=14, fontweight='bold', y=1.02)
        plt.tight_layout()
        
        if save_path:
            plt.savefig(save_path, dpi=300, bbox_inches='tight')
            print(f"📊 Grafico salvato in: {save_path}")
        
        plt.show()
    
    def plot_risk_analysis(self, save_path: Optional[str] = None) -> None:
        """
        Visualizza l'analisi del rischio.
        
        Parametri:
        ----------
        save_path : str, optional
            Percorso per salvare il grafico
        """
        if len(self.final_balances) == 0:
            self.run_simulation()
        
        stats = self.get_statistics()
        
        fig, axes = plt.subplots(1, 3, figsize=(16, 5))
        
        # 1. Profit/Loss Distribution
        ax1 = axes[0]
        profits = self.final_balances - self.initial_balance
        colors = ['green' if p > 0 else 'red' for p in profits]
        ax1.hist(profits, bins=50, color='steelblue', edgecolor='black', alpha=0.7)
        ax1.axvline(0, color='black', linestyle='-', linewidth=2)
        ax1.axvline(stats['var_95'], color='red', linestyle='--', 
                   linewidth=2, label=f'VaR 95%: ${stats["var_95"]:,.0f}')
        ax1.axvline(np.mean(profits), color='green', linestyle='-', 
                   linewidth=2, label=f'Media: ${np.mean(profits):,.0f}')
        ax1.set_xlabel('Profitto/Perdita ($)', fontsize=11)
        ax1.set_ylabel('Frequenza', fontsize=11)
        ax1.set_title('Distribuzione Profitto/Perdita', fontsize=12, fontweight='bold')
        ax1.legend(fontsize=9)
        ax1.xaxis.set_major_formatter(FuncFormatter(lambda x, p: f'${x:,.0f}'))
        
        # 2. Risk Metrics Gauge
        ax2 = axes[1]
        metrics = ['Prob. Profitto', 'Prob. Rovina', 'DD Medio', 'DD Peggiore']
        values = [stats['probability_of_profit'], 
                 stats['probability_of_ruin'],
                 stats['mean_max_drawdown'],
                 stats['worst_max_drawdown']]
        colors = ['green', 'red', 'orange', 'darkred']
        
        bars = ax2.barh(metrics, values, color=colors, alpha=0.7, edgecolor='black')
        
        for bar, val in zip(bars, values):
            ax2.text(bar.get_width() + 1, bar.get_y() + bar.get_height()/2,
                    f'{val:.1f}%', va='center', fontsize=10, fontweight='bold')
        
        ax2.set_xlabel('Percentuale (%)', fontsize=11)
        ax2.set_title('Metriche di Rischio', fontsize=12, fontweight='bold')
        ax2.set_xlim(0, max(values) * 1.2)
        
        # 3. Drawdown Duration Distribution
        ax3 = axes[2]
        sns.histplot(self.max_drawdown_durations, bins=30, kde=True, 
                    ax=ax3, color='purple', alpha=0.7)
        ax3.axvline(np.mean(self.max_drawdown_durations), color='orange', 
                   linestyle='--', linewidth=2, 
                   label=f'Media: {np.mean(self.max_drawdown_durations):.0f} trade')
        ax3.axvline(np.max(self.max_drawdown_durations), color='red', 
                   linestyle='-', linewidth=2, 
                   label=f'Max: {np.max(self.max_drawdown_durations):.0f} trade')
        ax3.set_xlabel('Durata Drawdown (trade)', fontsize=11)
        ax3.set_ylabel('Frequenza', fontsize=11)
        ax3.set_title('Distribuzione Durata Drawdown', fontsize=12, fontweight='bold')
        ax3.legend(fontsize=9)
        
        plt.suptitle('Analisi del Rischio Monte Carlo', 
                    fontsize=14, fontweight='bold', y=1.02)
        plt.tight_layout()
        
        if save_path:
            plt.savefig(save_path, dpi=300, bbox_inches='tight')
            print(f"📊 Grafico salvato in: {save_path}")
        
        plt.show()
    
    def export_results(self, output_path: str) -> None:
        """
        Esporta i risultati in un file CSV.
        
        Parametri:
        ----------
        output_path : str
            Percorso del file di output
        """
        if len(self.final_balances) == 0:
            self.run_simulation()
        
        stats = self.get_statistics()
        
        # Crea DataFrame con i risultati
        results_df = pd.DataFrame({
            'simulation': range(1, self.num_simulations + 1),
            'final_balance': self.final_balances,
            'max_drawdown': self.max_drawdowns,
            'max_dd_duration': self.max_drawdown_durations,
            'profit_loss': self.final_balances - self.initial_balance
        })
        
        results_df.to_csv(output_path, index=False)
        print(f"📁 Risultati esportati in: {output_path}")
        
        # Esporta anche le statistiche
        stats_path = output_path.replace('.csv', '_statistics.csv')
        stats_df = pd.DataFrame([stats])
        stats_df.to_csv(stats_path, index=False)
        print(f"📁 Statistiche esportate in: {stats_path}")


def load_mt5_report(file_path: str, separator: Optional[str] = None, use_net_profit: bool = True) -> pd.DataFrame:
    """
    Carica un report di backtest da MetaTrader 5 / EA_ORGANIC_Jarvis.
    
    Supporta formati:
    - CSV esportato da EA_ORGANIC_Jarvis (formato ottimizzato)
    - CSV/TXT con colonne: Time, Type, Volume, Price, Profit, Balance
    - HTML report da MT5
    - XML report da MT5
    - File copiati da clipboard MT5 (tab-separated)
    
    Parametri:
    ----------
    file_path : str
        Percorso del file report
    separator : str, optional
        Separatore per file CSV/TXT (auto-detect se None)
    use_net_profit : bool
        Se True usa NetProfit (profit+commission+swap), altrimenti Profit lordo
    
    Returns:
    --------
    pd.DataFrame
        DataFrame con i trade estratti
    """
    path = Path(file_path)
    
    if path.suffix.lower() in ['.csv', '.txt']:
        # Auto-detect separatore
        if separator is None:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                first_line = f.readline()
                if ';' in first_line:
                    separator = ';'
                elif '\t' in first_line:
                    separator = '\t'
                else:
                    separator = ','
        
        # Prova diverse codifiche
        df = None
        for encoding in ['utf-8', 'utf-16', 'latin-1', 'cp1252']:
            try:
                df = pd.read_csv(file_path, sep=separator, encoding=encoding)
                break
            except:
                continue
        
        if df is None:
            raise ValueError("Impossibile leggere il file con le codifiche supportate")
        
        # Rimuovi righe completamente vuote
        df = df.dropna(how='all')
        
        if len(df) == 0:
            raise ValueError("Il file non contiene dati validi")
        
        print(f"📂 File caricato: {path.name}")
        print(f"   Colonne trovate: {list(df.columns)}")
        print(f"   Righe totali: {len(df)}")
        
        # ═══════════════════════════════════════════════════════════════
        # FORMATO EA_ORGANIC_JARVIS (prioritario)
        # ═══════════════════════════════════════════════════════════════
        if 'NetProfit' in df.columns and use_net_profit:
            # Usa NetProfit che include già commission e swap
            df['profit'] = df['NetProfit'].apply(safe_numeric)
            print(f"   ✅ Usando colonna 'NetProfit' (profit netto)")
        elif 'Profit' in df.columns:
            df['profit'] = df['Profit'].apply(safe_numeric)
            # Se ci sono commission e swap, sommali
            if 'Commission' in df.columns:
                df['profit'] += df['Commission'].apply(safe_numeric).fillna(0)
            if 'Swap' in df.columns:
                df['profit'] += df['Swap'].apply(safe_numeric).fillna(0)
            print(f"   ✅ Usando colonna 'Profit' + Commission + Swap")
        else:
            # Cerca colonna profit (case insensitive, multi-lingua)
            profit_col = None
            profit_keywords = ['profit', 'profitto', 'lucro', 'gewinn', 'прибыль', 'netprofit']
            for col in df.columns:
                col_lower = str(col).lower()
                if any(kw in col_lower for kw in profit_keywords):
                    profit_col = col
                    break
            
            if profit_col is None:
                # Prova a cercare nella penultima o ultima colonna numerica
                numeric_cols = df.select_dtypes(include=[np.number]).columns
                if len(numeric_cols) >= 2:
                    profit_col = numeric_cols[-2]
                    print(f"   ⚠️ Colonna profit non trovata, uso: '{profit_col}'")
                else:
                    raise ValueError("Colonna 'Profit' non trovata nel file")
            
            df['profit'] = df[profit_col].apply(safe_numeric)
        
        # Filtra righe con profit valido
        df = df[df['profit'].notna()].copy()
        
        # Filtra righe con profit = 0 solo se sono chiaramente non-trade
        # (manteniamo trade con profit = 0 che sono chiusure in pareggio)
        
        if len(df) == 0:
            raise ValueError("Nessun trade valido trovato nel file dopo il parsing")
        
        # ═══════════════════════════════════════════════════════════════
        # ESTRAI BALANCE INIZIALE (se presente)
        # ═══════════════════════════════════════════════════════════════
        initial_balance = None
        if 'Balance' in df.columns:
            # Balance iniziale = primo balance - primo profit
            first_balance = safe_numeric(df['Balance'].iloc[0])
            first_profit = safe_numeric(df['profit'].iloc[0])
            if not np.isnan(first_balance) and not np.isnan(first_profit):
                initial_balance = first_balance - first_profit
                df.attrs['initial_balance'] = initial_balance
                print(f"   💰 Balance iniziale rilevato: ${initial_balance:,.2f}")
        
        print(f"   📊 Trade validi trovati: {len(df)}")
        
        return df
    
    elif path.suffix.lower() in ['.html', '.htm']:
        # Parsing per report HTML MT5
        try:
            tables = pd.read_html(file_path, encoding='utf-8')
        except:
            tables = pd.read_html(file_path, encoding='utf-16')
        
        # Cerca la tabella dei trade (quella più grande con colonne numeriche)
        best_table = None
        max_rows = 0
        
        for table in tables:
            # Cerca tabella con colonna profit-like
            for col in table.columns:
                col_str = str(col).lower()
                if 'profit' in col_str or 'deal' in col_str:
                    if len(table) > max_rows:
                        best_table = table
                        max_rows = len(table)
                    break
        
        if best_table is None:
            # Prendi la tabella più grande
            best_table = max(tables, key=len)
        
        # Trova colonna profit
        profit_col = None
        for col in best_table.columns:
            if 'profit' in str(col).lower():
                profit_col = col
                break
        
        if profit_col:
            best_table = best_table.rename(columns={profit_col: 'profit'})
            best_table['profit'] = pd.to_numeric(best_table['profit'], errors='coerce')
            best_table = best_table[best_table['profit'].notna()]
        
        print(f"✅ Caricati {len(best_table)} trade dal report HTML")
        return best_table
    
    elif path.suffix.lower() == '.xml':
        # Parsing per report XML MT5
        try:
            import xml.etree.ElementTree as ET
            tree = ET.parse(file_path)
            root = tree.getroot()
            
            trades = []
            # Cerca elementi Deal o Trade
            for deal in root.iter():
                if 'deal' in deal.tag.lower() or 'trade' in deal.tag.lower():
                    trade_data = {}
                    for child in deal:
                        trade_data[child.tag] = child.text
                    if deal.attrib:
                        trade_data.update(deal.attrib)
                    if trade_data:
                        trades.append(trade_data)
            
            if not trades:
                # Prova parsing alternativo (tabella)
                df_list = pd.read_xml(file_path)
                if isinstance(df_list, pd.DataFrame):
                    trades_df = df_list
                else:
                    raise ValueError("Struttura XML non riconosciuta")
            else:
                trades_df = pd.DataFrame(trades)
            
            # Cerca e rinomina colonna profit
            for col in trades_df.columns:
                if 'profit' in str(col).lower():
                    trades_df = trades_df.rename(columns={col: 'profit'})
                    trades_df['profit'] = pd.to_numeric(trades_df['profit'], errors='coerce')
                    trades_df = trades_df[trades_df['profit'].notna()]
                    break
            
            print(f"✅ Caricati {len(trades_df)} trade dal report XML")
            return trades_df
            
        except Exception as e:
            raise ValueError(f"Errore parsing XML: {e}")
    
    else:
        raise ValueError(f"Formato file non supportato: {path.suffix}\n"
                        f"Formati supportati: .csv, .txt, .html, .htm, .xml")


def create_sample_trades(n_trades: int = 200, 
                         win_rate: float = 0.55,
                         avg_win: float = 100,
                         avg_loss: float = -80,
                         seed: int = 42) -> List[float]:
    """
    Crea un set di trade di esempio per testing.
    
    Parametri:
    ----------
    n_trades : int
        Numero di trade (default: 200)
    win_rate : float
        Percentuale vincite (default: 0.55)
    avg_win : float
        Media vincita (default: 100)
    avg_loss : float
        Media perdita (default: -80)
    seed : int
        Seed per riproducibilità (default: 42)
    
    Returns:
    --------
    List[float]
        Lista dei profitti/perdite per trade
    """
    np.random.seed(seed)
    
    trades = []
    for _ in range(n_trades):
        if np.random.random() < win_rate:
            # Trade vincente con variabilità
            trade = np.random.exponential(avg_win)
        else:
            # Trade perdente con variabilità
            trade = -np.random.exponential(abs(avg_loss))
        trades.append(trade)
    
    return trades


# =============================================================================
# MAIN - Esempio di utilizzo
# =============================================================================
if __name__ == "__main__":
    print("\n" + "🚀"*35)
    print("  MONTE CARLO ANALYZER - EA ORGANIC JARVIS")
    print("🚀"*35 + "\n")
    
    # =========================================================================
    # OPZIONE 1: Usa trade di esempio per demo
    # =========================================================================
    print("📌 Creazione trade di esempio per demo...")
    sample_trades = create_sample_trades(
        n_trades=300,
        win_rate=0.58,
        avg_win=120,
        avg_loss=-90,
        seed=42
    )
    
    # Crea analyzer
    analyzer = MonteCarloAnalyzer(
        trades=sample_trades,
        initial_balance=10000,
        num_simulations=1000,
        confidence_level=0.95
    )
    
    # Esegui simulazione
    analyzer.run_simulation()
    
    # Stampa report
    analyzer.print_report()
    
    # Crea grafici
    print("\n📊 Generazione grafici...")
    analyzer.plot_equity_curves(num_curves=100, save_path='equity_curves.png')
    analyzer.plot_distribution(save_path='distribution.png')
    analyzer.plot_risk_analysis(save_path='risk_analysis.png')
    
    # Esporta risultati
    analyzer.export_results('montecarlo_results.csv')
    
    # =========================================================================
    # OPZIONE 2: Carica da file (decommentare per usare)
    # =========================================================================
    # print("📌 Caricamento report backtest...")
    # trades_df = load_mt5_report('path/to/your/backtest_report.csv')
    # 
    # analyzer = MonteCarloAnalyzer(
    #     trades=trades_df,
    #     initial_balance=10000,
    #     num_simulations=1000
    # )
    # analyzer.run_simulation()
    # analyzer.print_report()
    # analyzer.plot_equity_curves()
    
    print("\n✅ Analisi completata con successo!")
    print("="*70)
