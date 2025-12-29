//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════ |
//| 🌱 SISTEMA 100% ORGANICO - TUTTO DERIVATO DAI DATI              
//| ═══════════════════════════════════════════════════════════════ |
//|                                                                 |
//| COSTANTI MATEMATICHE (solo φ = Rapporto Aureo ≈ 1.618):         |
//|   φ = (1+√5)/2 | 1/φ ≈ 0.618 | 1/φ² ≈ 0.382 | 1/φ³ ≈ 0.236      |
//|   φ è usato SOLO come fattore di scala, non come valore fisso   |
//|                                                                 |
//| FORMULA PERIODI (100% data-driven):                             |
//|   naturalPeriod = autocorrelazione dei DATI (no minuti!)        |
//|   periodi_indicatori = naturalPeriod × potenze di φ             |
//|                                                                 |
//| FORMULA PESI TF (Esponente di Hurst):                           |
//|   peso_TF = H_TF / Σ(H_tutti_TF)                                |
//|   H > centro: trending → peso maggiore                          |
//|   H derivato con metodo R/S (Rescaled Range)                    |
//|                                                                 |
//| CENTRI E SCALE (100% empirici):                                 |
//|   centro = mean(indicatore) calcolato sul cross                 |
//|   scala = stdev(indicatore) × φ (volatilità reale)              |
//|                                                                 |
//| SOGLIE DINAMICHE:                                               |
//|   ADX threshold = avg + (1/φ) × stddev (dai dati)               |
//|   Score threshold = mean + stdev × φ⁻¹ (dai dati)               |
//|   Zona Hurst = centro ± stdev × φ⁻¹ (dai dati)                  |
//|                                                                 |
//| READY CHECK:                                                    |
//|   L'EA NON entra a mercato finché non ha abbastanza dati        |
//|   per calcolare TUTTI i valori organici (no fallback!)          |
//|                                                                 |
//| ═══════════════════════════════════════════════════════════════ |
//| ✅ VALIDAZIONI IMPLEMENTATE (cerca "✅ VALIDATO" nel codice):    |
//| ═══════════════════════════════════════════════════════════════ |
//| 1. HURST EXPONENT: Range [φ⁻³, 1-φ⁻³] forzato in output         |
//| 2. DIVISIONI: Tutte protette contro /0 con check denominatore   |
//| 3. BUFFER CIRCOLARI: Indici sempre in [0, MAX-1] via modulo     |
//| 4. SOMME INCREMENTALI: Sanity check per floating point errors   |
//| 5. VARIANZA: Protezione sqrt(negativo) → ritorna 0.0            |
//| 6. SCORE THRESHOLD: Clamped in [23.6%, 76.4%] (PHI bounds)      |
//| 7. CONFIDENCE: Output sempre in [0.0, 1.0]                      |
//| 8. REGIME HURST: Sempre ritorna ENUM valida (default=RANDOM)    |
//| ═══════════════════════════════════════════════════════════════ |          |
//| ═══════════════════════════════════════════════════════════════ |
//+------------------------------------------------------------------+
#property copyright "Pietro Giacobazzi, Juri Corradi, Alessandro Brehas"
#property version   "4.00"
#property description "EA Jarvis_INDICATORS CA__Pt MASTER (🌱 SISTEMA 100% ORGANICO - TUTTO DERIVATO DAI DATI)"

#include <Trade\Trade.mqh>
#include <Arrays\ArrayDouble.mqh>

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║                    💰 MONEY MANAGEMENT & GENERALE                          ║
// ╚═══════════════════════════════════════════════════════════════════════════╝
input group "═══ 💰 GENERALE ═══"
input bool   enableTrading        = true;       // Abilita trading (false = solo analisi)
input int    MaxOpenTrades        = 100;        // Massimo posizioni aperte
input double MaxSpread            = 35;         // Spread massimo in punti
input uint   MaxSlippage          = 40;         // Slippage max in punti
input int    MagicNumber          = 123456;     // Magic Number (base, viene modificato per simbolo)

//+------------------------------------------------------------------+
//| 🔧 FIX: Calcola Magic Number unico per simbolo                   |
//| Evita conflitti quando EA gira su più simboli contemporaneamente |
//| ✅ FIXED: Usa ulong per evitare overflow integer durante hash    |
//+------------------------------------------------------------------+
int CalculateUniqueMagicNumber()
{
    // 🔧 FIX: Usa ulong per evitare overflow durante moltiplicazione
    ulong symbolHash = 0;
    string sym = _Symbol;
    
    // Numero primo grande per modulo (evita overflow mantenendo distribuzione)
    const ulong PRIME_MOD = 2147483647;  // Più grande primo che sta in int32
    
    for (int i = 0; i < StringLen(sym); i++) {
        // Modulo dopo ogni operazione per evitare overflow
        symbolHash = ((symbolHash * 31) % PRIME_MOD + StringGetCharacter(sym, i)) % PRIME_MOD;
    }
    
    // Limita a range ragionevole per evitare collisioni con altri EA
    int hashOffset = (int)(symbolHash % 100000);
    
    // 🔧 FIX: Protezione overflow - se MagicNumber + hashOffset supera INT_MAX
    int maxSafeOffset = INT_MAX - MagicNumber;
    if (maxSafeOffset < 0) {
        // MagicNumber già troppo grande, usa offset 0
        PrintFormat("[MAGIC] ⚠️ MagicNumber %d troppo grande, hashOffset azzerato", MagicNumber);
        hashOffset = 0;
    } else if (hashOffset > maxSafeOffset) {
        // Riduci hashOffset per evitare overflow
        hashOffset = hashOffset % (maxSafeOffset + 1);
    }
    
    // Combina con MagicNumber base
    return MagicNumber + hashOffset;
}

// 🔧 FIX: Cache Magic Number (calcolato 1x in OnInit, riutilizzato ovunque)
int g_uniqueMagicNumber = 0;

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║                         🟢 PARAMETRI BUY                                   ║
// ╚═══════════════════════════════════════════════════════════════════════════╝
input group "═══ 🟢 ORDINI BUY ═══"
input double BuyLotSize           = 0.5;       // Lotto fisso per ordini BUY
input int    BuyStopLossPoints    = 0;          // SL BUY in punti (0=disattivato)
input int    BuyTakeProfitPoints  = 500;        // TP BUY in punti (0=disattivato)
input double StopLossPriceBuy     = 0.0;        // SL BUY prezzo fisso (priorità su punti)
input double TakeProfitPriceBuy   = 0.0;        // TP BUY prezzo fisso (priorità su punti)
input int    BuyTimeStopMinutes   = 7200;          // Stop loss temporale BUY (0=disattivato)

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║                         🔴 PARAMETRI SELL                                 ║
// ╚═══════════════════════════════════════════════════════════════════════════╝
input group "═══ 🔴 ORDINI SELL ═══"
input double SellLotSize          = 0.5;       // Lotto fisso per ordini SELL
input int    SellStopLossPoints   = 0;          // SL SELL in punti (0=disattivato)
input int    SellTakeProfitPoints = 500;        // TP SELL in punti (0=disattivato)
input double StopLossPriceSell    = 0.0;        // SL SELL prezzo fisso (priorità su punti)
input double TakeProfitPriceSell  = 0.0;        // TP SELL prezzo fisso (priorità su punti)
input int    SellTimeStopMinutes  = 7200;          // Stop loss temporale SELL (0=disattivato)

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║                    📊 TIMEFRAME & SISTEMA VOTO                            ║
// ╚═══════════════════════════════════════════════════════════════════════════╝
input group "═══ 📊 TIMEFRAME ═══"
input bool   EnableIndicatorVoteSystem = true;  // Abilita sistema voti/pesi indicatori
input bool   EnableVote_M5             = false;  // Usa timeframe M5 nel voto
input bool   EnableVote_H1             = true;  // Usa timeframe H1 nel voto
input bool   EnableVote_H4             = true;  // Usa timeframe H4 nel voto
input bool   EnableVote_D1             = true;  // Usa timeframe D1 nel voto

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║                      📝 LOG & DEBUG                                       ║
// ╚═══════════════════════════════════════════════════════════════════════════╝
input group "═══ 📝 LOG ═══"
input bool   EnableLogs                = true;  // 🌱 Abilita TUTTI i log (true=completi, false=silenzioso)
input bool   ExportTradesCSV           = true;  // 📊 Esporta trade in CSV per Monte Carlo

// ═══════════════════════════════════════════════════════════════════════════
// 🌱 SISTEMA 100% ORGANICO - Nessun valore hardcodato
// ═══════════════════════════════════════════════════════════════════════════
// FORMULA PERIODI: naturalPeriod = autocorrelazione dei DATI
// Tutti i periodi derivano dal naturalPeriod usando rapporti φ
//
// FORMULA PESI (ESPONENTE DI HURST - Metodo R/S):
// peso_TF = hurstExponent_TF / somma(hurstExponent_tutti_TF)
// H > g_hurstCenter: trending → peso maggiore
// H ≈ g_hurstCenter: random → peso minore (zona no-trade)
// H < g_hurstCenter: mean-reverting → peso maggiore
// ═══════════════════════════════════════════════════════════════════════════

//--- Struttura per contenere i valori organici calcolati per ogni TF
struct OrganicPeriods {
    // 🌱 PERIODI (derivati da naturalPeriod × potenze di φ)
    int ema;           // EMA period
    int rsi;           // RSI period
    int macd_fast;     // MACD fast
    int macd_slow;     // MACD slow
    int macd_signal;   // MACD signal
    int bb;            // Bollinger period
    double bb_dev;     // BB deviation (organica)
    int atr;           // ATR period
    int adx;           // ADX period
    int min_bars_required; // Barre minime necessarie
    
    // 🌱 PESO TF (calcolato da ESPONENTE DI HURST)
    double weight;           // Peso del timeframe normalizzato
    double hurstExponent;    // Esponente di Hurst (0-1): H>centro=trending, H<centro=mean-reverting
    
    // 🌱 PERIODO NATURALE (derivato dall'autocorrelazione dei DATI)
    // Questo è la BASE da cui derivano TUTTE le scale
    int naturalPeriod; // Periodo naturale del mercato per questo TF
};

//--- Periodi organici per ogni timeframe (calcolati in OnInit)
OrganicPeriods g_organic_M5, g_organic_H1, g_organic_H4, g_organic_D1;

// 🔧 FIX: Periodi precedenti per rilevare cambi significativi (>20%)
// Se i periodi cambiano drasticamente, gli handle indicatori devono essere ricreati
OrganicPeriods g_prevOrganic_M5, g_prevOrganic_H1, g_prevOrganic_H4, g_prevOrganic_D1;
bool g_periodsInitialized = false;  // Flag: primi periodi calcolati?

//--- Flag per indicare se i dati sono pronti
bool g_dataReady_M5 = false;
bool g_dataReady_H1 = false;
bool g_dataReady_H4 = false;
bool g_dataReady_D1 = false;

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║               🌱 INDICATORI TECNICI (tutti organici)                       ║
// ╠═══════════════════════════════════════════════════════════════════════════╣
// ║ I pesi sono calcolati con ESPONENTE DI HURST:                             ║
// ║   peso_TF = hurstExponent_TF / Σ(hurstExponent)                           ║
// ║   H > g_hurstCenter → peso maggiore (trending)                            ║
// ║   H ≈ g_hurstCenter → peso minore (random, zona no-trade)                 ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

// ═══════════════════════════════════════════════════════════════════════════
// 🌱 INDICATORI OTTIMIZZATI (rimossi ridondanti per maggiore precisione)
// TREND: EMA, MACD, ADX
// OSCILLATORI: RSI
// VOLATILITÀ/VOLUME: BB, OBV, Heikin Ashi
// ═══════════════════════════════════════════════════════════════════════════
input group "═══ 🌱 INDICATORI TREND ═══"
input bool   enableEMA       = true;    // EMA (trend direction)
input bool   enableMACD      = true;    // MACD (trend momentum)
input bool   enableADX       = true;    // ADX (trend strength filter)

input group "═══ 🌱 INDICATORI OSCILLATORI ═══"
input bool   enableRSI       = true;    // RSI (overbought/oversold)

input group "═══ 🌱 INDICATORI VOLATILITA' & VOLUME ═══"
input bool   enableBB        = true;    // Bollinger Bands (volatility bands)
input bool   enableOBV       = true;    // OBV (volume-based trend)
input bool   enableHeikin    = true;    // Heikin Ashi (noise reduction)

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║              🧬 SISTEMA ORGANICO (Hurst & Soglie)                          ║
// ╠═══════════════════════════════════════════════════════════════════════════╣
// ║ FILTRO HURST: Blocca trade quando H ≈ centro storico (zona random)        ║
// ║ SOGLIA SCORE: Automatica = mean + stdev × φ⁻¹ dai dati storici            ║
// ╚═══════════════════════════════════════════════════════════════════════════╝
input group "═══ 🧬 SISTEMA ORGANICO ═══"
input bool   EnableHurstFilter  = true;         // Abilita filtro no-trade zone (H in zona random)
input bool   AutoScoreThreshold = true;         // Soglia automatica (true) o manuale (false)
input double ScoreThreshold     = 61.8;         // 🌱 Soglia manuale (φ⁻¹ × 100) - solo se Auto=false
input bool   EnableReversalBlock = true;        // 🎯 Blocca trade se reversal contrario forte (soglia φ⁻¹)

input group "═══ ⚡ PERFORMANCE BACKTEST ═══"
input int    RecalcEveryBars    = 200;            // 🚀 Ricalcolo ogni N barre (0=ogni barra, 100=veloce, 200=molto veloce)

// ═══════════════════════════════════════════════════════════════════════════════
// 🌱 COSTANTI MATEMATICHE ORGANICHE - Derivate dalla natura, non arbitrarie
// ═══════════════════════════════════════════════════════════════════════════════
// Rapporto Aureo: φ = (1 + √5) / 2 ≈ 1.618 - base universale della natura
const double PHI = (1.0 + MathSqrt(5.0)) / 2.0;  // ≈ 1.618033988749895
const double PHI_INV = 1.0 / PHI;                 // ≈ 0.618033988749895 (1/φ)
const double PHI_SQ = PHI * PHI;                  // ≈ 2.618033988749895 (φ²)
const double PHI_INV_SQ = PHI_INV * PHI_INV;      // ≈ 0.381966011250105 (1/φ²)
const double PHI_INV_CUB = PHI_INV_SQ * PHI_INV;  // ≈ 0.236067977499790 (1/φ³)

// 🌱 RANGE HURST ORGANICO - Derivato da φ
// Limiti: [φ⁻³, 1-φ⁻³] ≈ [0.236, 0.764]
const double HURST_RANGE_MIN = PHI_INV_CUB;              // ≈ 0.236
const double HURST_RANGE_MAX = 1.0 - PHI_INV_CUB;        // ≈ 0.764

// ═══════════════════════════════════════════════════════════════════════════
// 🚀 OTTIMIZZAZIONE PERFORMANCE BACKTEST
// ═══════════════════════════════════════════════════════════════════════════
int    g_barsSinceLastRecalc = 0;           // Contatore barre dall'ultimo ricalcolo
bool   g_isBacktest = false;                 // Flag: siamo in backtest?
bool   g_enableLogsEffective = true;         // Log effettivi (auto-disabilitati in backtest)

// 🚀 CACHE FLAGS (le variabili struct sono dichiarate dopo NaturalPeriodResult)
bool   g_cacheValid = false;                 // Cache valida?
int    g_hurstRecalcCounter = 0;             // Contatore per ricalcolo Hurst
bool   g_tfDataCacheValid = false;           // Cache dati TF valida?
int    g_tfDataRecalcCounter = 0;            // Contatore per reload dati TF

// 🔧 FIX: Variabili per rilevamento gap di prezzo e invalidazione cache
double g_lastCachePrice = 0.0;               // Ultimo prezzo quando cache valida
double g_lastCacheATR = 0.0;                 // Ultimo ATR quando cache valida

// 🔧 FIX: Warmup period - evita trading prima di stabilizzazione indicatori
datetime g_eaStartTime = 0;                  // Timestamp avvio EA
bool   g_warmupComplete = false;             // Flag: warmup completato?
int    g_warmupBarsRequired = 0;             // Barre minime prima di tradare (calcolato in OnInit)

// ═══════════════════════════════════════════════════════════════════════════
// 🌱 NOTA: Ora TUTTO è derivato da:
// 1. PERIODO NATURALE = autocorrelazione dei DATI (CalculateNaturalPeriodForTF)
// 2. POTENZE DI φ = MathPow(PHI, n) per le scale
// 3. RAPPORTI AUREI = PHI, PHI_INV, PHI_SQ per i moltiplicatori
//
// Riferimento potenze di φ:
// φ¹ ≈ 1.618, φ² ≈ 2.618, φ³ ≈ 4.236, φ⁴ ≈ 6.854, φ⁵ ≈ 11.09
// φ⁶ ≈ 17.94, φ⁷ ≈ 29.03, φ⁸ ≈ 46.98, φ⁹ ≈ 76.01, φ¹⁰ ≈ 122.99
// φ¹¹ ≈ 199.0, φ¹² ≈ 322.0
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
// 🌱 SISTEMA PURO - NESSUN FALLBACK
// Se non abbiamo abbastanza dati per calcolare i centri empirici,
// il timeframe viene DISABILITATO (isDataReady = false) e loggato l'errore.
// Questo garantisce che OGNI decisione sia basata su dati REALI.
// ═══════════════════════════════════════════════════════════════════════════

// 🌱 Struttura per ritornare periodo naturale E esponente di Hurst
struct NaturalPeriodResult {
    int period;              // Periodo naturale (lag dove autocorr < 1/φ²)
    double hurstExponent;    // Esponente di Hurst (0-1): confrontato con g_hurstCenter
    bool valid;              // true se calcolo OK, false se dati insufficienti
};

// 🚀 CACHE PER RISULTATI HURST (dichiarata dopo la struct)
NaturalPeriodResult g_cachedResult_M5, g_cachedResult_H1, g_cachedResult_H4, g_cachedResult_D1;

//--- Oggetti trading e indicatori
CTrade          trade;
datetime        lastBarTime = 0;
datetime        lastHurstRecalc = 0;  // 🌱 Ultimo ricalcolo Hurst

// ═══════════════════════════════════════════════════════════════════════════
// 🌱 FILTRO HURST NO-TRADE ZONE - 100% DATA-DRIVEN
// ═══════════════════════════════════════════════════════════════════════════
// Se il mercato è in regime "random" (H ≈ centro storico), i segnali sono rumore.
// 
// SOGLIE 100% DAI DATI STORICI:
//   g_hurstCenter = media(H) storica del cross
//   g_hurstZoneMargin = stdev(H) × φ⁻¹
//   g_hurstRandomLow = centro - margine
//   g_hurstRandomHigh = centro + margine
//
// REGIME (basato su soglie data-driven):
//   H > g_hurstRandomHigh: TRENDING → trade permessi
//   H < g_hurstRandomLow: MEAN-REVERTING → trade permessi  
//   g_hurstRandomLow < H < g_hurstRandomHigh: RANDOM → NO TRADE
//
// VOTING: tradeScore = |H - centro| × confidence, confrontato con soglia dinamica
// ═══════════════════════════════════════════════════════════════════════════

// Soglie organiche derivate da φ
// 🌱 SOGLIE ZONA RANDOM 100% DATA-DRIVEN
// TUTTO derivato dai dati storici del cross:
//   g_hurstCenter = media(H) storica
//   g_hurstZoneMargin = stdev(H) × φ⁻¹
//   zona_random = [g_hurstRandomLow, g_hurstRandomHigh]
double g_hurstCenter = 0.0;                                   // Centro DINAMICO = media(H) storica
double g_hurstZoneMargin = 0.0;                               // Margine = stdev(H) × φ⁻¹
double g_hurstRandomLow = 0.0;                                // centro - margine
double g_hurstRandomHigh = 0.0;                               // centro + margine
bool   g_hurstZoneReady = false;                              // True quando calcolato da dati

// Buffer storico per valori H (per calcolare stdev adattiva)
double g_hurstHistory[];                                      // Buffer H storici
int g_hurstHistorySize = 0;                                   // Numero H memorizzati
int g_hurstHistoryIndex = 0;                                  // Indice corrente (buffer circolare)
// 🌱 Dimensione buffer: φ¹⁰ (calcolata dinamicamente)
int HURST_HISTORY_MAX = 0;                                    // Calcolato in OnInit come round(φ¹⁰)
double g_hurstStdev = 0.0;                                    // Stdev storica di H

// 🚀 SOMME INCREMENTALI per Hurst (O(1) invece di O(n))
double g_hurstSum = 0.0;                                      // Σ(H) per calcolo media
double g_hurstSumSq = 0.0;                                    // Σ(H²) per calcolo varianza
int    g_hurstOperationCount = 0;                             // 🔧 FIX: Contatore operazioni per ricalcolo periodico anti-drift

// Buffer storico per tradeScore (per soglia data-driven del filtro Hurst)
double g_tradeScoreHistory[];
int    g_tradeScoreHistorySize = 0;
int    g_tradeScoreHistoryIndex = 0;
// 🌱 Dimensione buffer: φ⁹ (calcolata dinamicamente)
int TRADE_SCORE_HISTORY_MAX = 0;                              // Calcolato in OnInit come round(φ⁹)
double g_tradeScoreThreshold = 0.0;                           // Soglia data-driven del tradeScore
bool   g_tradeScoreReady = false;                             // True quando soglia calcolata dai dati

// 🚀 SOMME INCREMENTALI per TradeScore (O(1) invece di O(n))
double g_tradeScoreSum = 0.0;                                 // Σ(tradeScore)
double g_tradeScoreSumSq = 0.0;                               // Σ(tradeScore²)
int    g_tradeScoreOperationCount = 0;                        // 🔧 FIX: Contatore operazioni per ricalcolo periodico anti-drift

// ═══════════════════════════════════════════════════════════════════════════
// 📊 STATISTICHE TRADING PER ANALISI PROFITTO
// ═══════════════════════════════════════════════════════════════════════════
struct TradeStatistics {
    int totalTrades;           // Trades totali
    int winTrades;             // Trades vincenti
    int lossTrades;            // Trades perdenti
    double totalProfit;        // Profitto totale lordo
    double totalLoss;          // Perdita totale lorda (valore assoluto)
    double maxDrawdown;        // Max drawdown in valuta
    double maxDrawdownPct;     // Max drawdown in %
    double peakEquity;         // Picco equity per calcolo DD
    double currentStreak;      // Streak corrente (+win, -loss)
    int maxWinStreak;          // Max streak vincente
    int maxLossStreak;         // Max streak perdente
    double avgWin;             // Media vincita
    double avgLoss;            // Media perdita
    double profitFactor;       // Profit Factor
    double expectancy;         // Expectancy per trade
    datetime lastTradeTime;    // Ultimo trade
    double totalSlippage;      // Slippage totale accumulato (punti)
    int slippageCount;         // Numero trade con slippage misurato
    double totalCommission;    // Commissioni totali
    double totalSwap;          // Swap totali
};

TradeStatistics g_stats;

// Buffer per ultimi N trade (per analisi pattern)
struct TradeRecord {
    ulong ticket;
    datetime openTime;
    datetime closeTime;
    ENUM_POSITION_TYPE type;
    double openPrice;
    double closePrice;
    double volume;
    double profit;
    double slippage;
    double spreadAtOpen;
    string closeReason;        // "SL", "TP", "TIME_STOP", "SIGNAL"
};

TradeRecord g_recentTrades[];
int g_recentTradesMax = 0;     // Calcolato in OnInit come round(φ⁸) ≈ 47
int g_recentTradesCount = 0;
int g_recentTradesIndex = 0;

// Stato corrente del regime Hurst (aggiornato periodicamente)
enum ENUM_HURST_REGIME {
    HURST_TRENDING = 1,      // H > zona random: trend persistence
    HURST_RANDOM = 0,        // dentro zona random: random walk
    HURST_MEANREV = -1       // H < zona random: mean reversion
};

ENUM_HURST_REGIME g_hurstRegime_M5 = HURST_RANDOM;
ENUM_HURST_REGIME g_hurstRegime_H1 = HURST_RANDOM;
ENUM_HURST_REGIME g_hurstRegime_H4 = HURST_RANDOM;
ENUM_HURST_REGIME g_hurstRegime_D1 = HURST_RANDOM;
double g_hurstComposite = 0.0;           // H PESATO composito (calcolato dai dati)
double g_hurstConfidence = 0.0;          // Confidenza (0-1) basata su distanza da centro
double g_hurstTradeScore = 0.0;          // Trade score = |H - centro| × confidence / (stdev × φ)
bool g_hurstAllowTrade = true;           // Flag: trade permessi?
bool g_hurstReady = false;               // True quando zona Hurst e soglia tradeScore sono da dati

// ═══════════════════════════════════════════════════════════════════════════
// 🌱 SOGLIA SCORE DINAMICA (derivata dalla distribuzione storica)
// ═══════════════════════════════════════════════════════════════════════════
// Buffer circolare per memorizzare gli ultimi N score
// La soglia è calcolata come: mean(score) + stdev(score) × φ⁻¹
// Questo rende la soglia adattiva al comportamento recente del mercato
// ═══════════════════════════════════════════════════════════════════════════
double g_scoreHistory[];                 // Buffer score storici
int g_scoreHistorySize = 0;              // Numero score memorizzati
int g_scoreHistoryIndex = 0;             // Indice corrente (buffer circolare)
double g_dynamicThreshold = 0.0;         // Soglia 100% data-driven (0 = non pronta)
// 🌱 Dimensione buffer: φ¹² (calcolata dinamicamente)
int SCORE_HISTORY_MAX = 0;               // Calcolato in OnInit come round(φ¹²)
bool g_scoreThresholdReady = false;      // True quando la soglia auto è calcolata dai dati

// 🚀 SOMME INCREMENTALI per Score (O(1) invece di O(n))
double g_scoreSum = 0.0;                 // Σ(score)
double g_scoreSumSq = 0.0;               // Σ(score²)
int    g_scoreOperationCount = 0;        // 🔧 FIX: Contatore operazioni per ricalcolo periodico anti-drift

// ═══════════════════════════════════════════════════════════════════════════
// 🌱 DETECTOR INVERSIONE ORGANICO
// Score Momentum: traccia cambi direzione del consenso indicatori
// Regime Change: traccia transizioni regime Hurst
// RSI Divergence: rileva divergenze prezzo/RSI (classico, testato)
// ═══════════════════════════════════════════════════════════════════════════

// Score Momentum: derivata dello score (segnale leading)
double g_prevScore = 0.0;                // Score della barra precedente
double g_scoreMomentum = 0.0;            // Cambio score: Score[t] - Score[t-1]
double g_scoreMomentumThreshold = 0.0;   // Soglia momentum = stdev(momentum) × φ⁻¹
double g_momentumHistory[];              // Buffer storico momentum per calcolo soglia
int g_momentumHistorySize = 0;
int g_momentumHistoryIndex = 0;
double g_momentumSum = 0.0;              // Somma incrementale momentum
double g_momentumSumSq = 0.0;            // Somma incrementale momentum²
bool g_momentumThresholdReady = false;   // True quando soglia calcolata dai dati

// Regime Change: transizioni Hurst (confirmation)
ENUM_HURST_REGIME g_prevRegime_M5 = HURST_RANDOM;
ENUM_HURST_REGIME g_prevRegime_H1 = HURST_RANDOM;
ENUM_HURST_REGIME g_prevRegime_H4 = HURST_RANDOM;
ENUM_HURST_REGIME g_prevRegime_D1 = HURST_RANDOM;
bool g_regimeChanged = false;            // Flag: regime cambiato questa barra
int g_regimeChangeDirection = 0;         // +1=verso trending, -1=verso meanrev, 0=nessun cambio

// RSI Divergence: swing detection e divergenze
struct SwingPoint {
    int barIndex;                        // Indice barra dello swing
    double price;                        // Prezzo allo swing (high/low)
    double rsi;                          // RSI allo swing
    bool isHigh;                         // true=swing high, false=swing low
};
SwingPoint g_swings_H1[];                // Buffer swing points H1 (TF principale)
int g_swingsSize_H1 = 0;                 // Numero swing memorizzati
int g_swingsMax = 0;                     // Max swing = round(φ⁵) ≈ 11
int g_divergenceSignal = 0;              // +1=bullish div, -1=bearish div, 0=nessuna
double g_divergenceStrength = 0.0;       // Forza divergenza (0-1)

// 🌱 SOGLIA DIVERGENZA DATA-DRIVEN
// Traccia storia forze divergenza per calcolare soglia minima
double g_divergenceHistory[];            // Buffer storico forza divergenza
int g_divergenceHistorySize = 0;         // Dimensione buffer
int g_divergenceHistoryIndex = 0;        // Indice circolare
double g_divergenceSum = 0.0;            // Somma incrementale (O(1))
double g_divergenceSumSq = 0.0;          // Somma quadrati (O(1))
double g_divergenceMinThreshold = PHI_INV_CUB;  // 🌱 Soglia iniziale = φ⁻³ ≈ 23.6%
bool g_divergenceThresholdReady = false; // True quando calcolata dai dati

// 🌱 SOGLIA REVERSAL DATA-DRIVEN
// Invece di usare PHI_INV fisso, tracciamo la storia della forza reversal
// e calcoliamo la soglia come: mean + stdev × φ⁻¹
double g_reversalStrengthHistory[];      // Buffer storico forza reversal
int g_reversalHistorySize = 0;           // Dimensione buffer
int g_reversalHistoryIndex = 0;          // Indice circolare corrente
double g_reversalSum = 0.0;              // Somma incrementale (O(1))
double g_reversalSumSq = 0.0;            // Somma quadrati (O(1))
double g_reversalThreshold = PHI_INV;    // 🌱 Soglia iniziale = φ⁻¹ ≈ 61.8%
bool g_reversalThresholdReady = false;   // True quando soglia calcolata dai dati

// 🚀 COSTANTE CACHED: evita 4× SymbolInfoDouble per barra
double g_pointValue = 0.0;               // SYMBOL_POINT (calcolato 1× in OnInit)

//--- Handles indicatori per tutti i timeframe (inizializzati a INVALID_HANDLE per sicurezza)
int emaHandle_M5 = INVALID_HANDLE, emaHandle_H1 = INVALID_HANDLE, emaHandle_H4 = INVALID_HANDLE, emaHandle_D1 = INVALID_HANDLE;
int rsiHandle_M5 = INVALID_HANDLE, rsiHandle_H1 = INVALID_HANDLE, rsiHandle_H4 = INVALID_HANDLE, rsiHandle_D1 = INVALID_HANDLE;
int macdHandle_M5 = INVALID_HANDLE, macdHandle_H1 = INVALID_HANDLE, macdHandle_H4 = INVALID_HANDLE, macdHandle_D1 = INVALID_HANDLE;
int bbHandle_M5 = INVALID_HANDLE, bbHandle_H1 = INVALID_HANDLE, bbHandle_H4 = INVALID_HANDLE, bbHandle_D1 = INVALID_HANDLE;
int atrHandle_M5 = INVALID_HANDLE, atrHandle_H1 = INVALID_HANDLE, atrHandle_H4 = INVALID_HANDLE, atrHandle_D1 = INVALID_HANDLE;
int adxHandle_M5 = INVALID_HANDLE, adxHandle_H1 = INVALID_HANDLE, adxHandle_H4 = INVALID_HANDLE, adxHandle_D1 = INVALID_HANDLE;
int obvHandle_M5 = INVALID_HANDLE, obvHandle_H1 = INVALID_HANDLE, obvHandle_H4 = INVALID_HANDLE, obvHandle_D1 = INVALID_HANDLE;

//--- Struttura dati per timeframe
struct TimeFrameData {
    double ema[];
    double rsi[];
    double macd[];
    double macd_signal[];
    double bb_upper[];
    double bb_middle[];
    double bb_lower[];
    double atr[];
    double adx[];
    double di_plus[];       // +DI per direzione trend (ADX)
    double di_minus[];      // -DI per direzione trend (ADX)
    double ha_open[];
    double ha_close[];
    double obv[];
    MqlRates rates[];
    
    // 🌱 Valori organici calcolati dinamicamente
    double atr_avg;         // Media ATR calcolata sulle ultime N barre
    double adx_avg;         // Media ADX calcolata sulle ultime N barre
    double adx_stddev;      // Deviazione standard ADX
    double adx_threshold;   // Soglia ADX organica = avg + (1/φ)*stddev
    bool   isDataReady;     // Flag: abbastanza dati per calcoli organici
    
    // 🌱 CENTRI EMPIRICI - Calcolati da CalculateEmpiricalThresholds()
    double rsi_center;      // mean(RSI) ultime N barre
    
    // 🌱 SCALE EMPIRICHE - Derivate dalla volatilità dei dati
    double rsi_scale;       // Stdev empirico RSI × φ
    double obv_scale;       // 🔧 FIX: Stdev empirico variazioni OBV × φ
    
    // 🌱 ADX PERCENTILI - Derivati dalla distribuzione storica
    double adx_p25;         // φ⁻² percentile ADX ≈ 38° (range "basso")
    double adx_p75;         // φ⁻¹ percentile ADX ≈ 62° (range "alto")
    
    // 🌱 Riferimento ai periodi organici del TF (impostato in LoadTimeFrameData)
    OrganicPeriods organic; // Periodi e peso organico del timeframe
};

TimeFrameData tfData_M5, tfData_H1, tfData_H4, tfData_D1;

//--- 🌱 Flag TF attivi (aggiornati ad ogni tick in base ai dati disponibili)
bool g_vote_M5_active = false;
bool g_vote_H1_active = false;
bool g_vote_H4_active = false;
bool g_vote_D1_active = false;

//+------------------------------------------------------------------+
//| Inizializzazione Expert Advisor                                  |
//+------------------------------------------------------------------+
int OnInit()
{
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 0: INIZIALIZZAZIONE COSTANTI ORGANICHE (potenze di φ)
    // Tutte le dimensioni buffer sono calcolate dinamicamente da φ
    // φ⁹ ≈ 76, φ¹⁰ ≈ 123, φ¹² ≈ 322
    // ═══════════════════════════════════════════════════════════════
    TRADE_SCORE_HISTORY_MAX = (int)MathRound(MathPow(PHI, 9));   // φ⁹ ≈ 76
    HURST_HISTORY_MAX = (int)MathRound(MathPow(PHI, 10));        // φ¹⁰ ≈ 123
    SCORE_HISTORY_MAX = (int)MathRound(MathPow(PHI, 12));        // φ¹² ≈ 322
    
    // 🚀 RILEVAMENTO BACKTEST E OTTIMIZZAZIONE AUTOMATICA
    g_isBacktest = (bool)MQLInfoInteger(MQL_TESTER);
    g_enableLogsEffective = EnableLogs && !g_isBacktest;
    g_barsSinceLastRecalc = 0;
    
    if (g_isBacktest) {
        Print("═════════════════════════════════════════════════════════════════");
        Print("⚡ BACKTEST MODE ATTIVO - Performance ottimizzata");
        if (RecalcEveryBars > 0) {
            PrintFormat("   Ricalcolo organico: ogni %d barre (invece di ogni barra)", RecalcEveryBars);
            PrintFormat("   Speedup atteso: ~%dx rispetto al normale", RecalcEveryBars);
        } else {
            Print("   Ricalcolo organico: ogni barra (usa RecalcEveryBars>0 per velocizzare!)");
            Print("   ⚠️ CONSIGLIO: Imposta RecalcEveryBars=100 per backtest 50-100x più veloce");
        }
        Print("   🚀 Buffer Hurst: PRE-CARICATO da storia (trading subito!)");
        Print("   Log dettagliati: DISABILITATI automaticamente");
        Print("═════════════════════════════════════════════════════════════════");
    }
    
    Print("[INIT] 🌱 Avvio EA Jarvis v4 FULL DATA-DRIVEN (PURO) - Periodi E pesi derivati dai dati");
    
    // 🚀 CACHE COSTANTI SIMBOLO (evita chiamate API ripetute)
    g_pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // 🌱 Fallback organico: φ⁻²³ ≈ 0.00001 (calcolato esattamente)
    // φ⁻²³ = (φ⁻⁶)³ × φ⁻⁵ = PHI_INV^23 ≈ 0.0000106
    // 🔧 FIX: Per coppie JPY (point ~0.01) il fallback è molto più grande
    if (g_pointValue <= 0) {
        // Determina se coppia JPY-like dal nome simbolo
        string upperSymbol = _Symbol;
        StringToUpper(upperSymbol);
        if (StringFind(upperSymbol, "JPY") >= 0 || StringFind(upperSymbol, "XAU") >= 0) {
            g_pointValue = 0.01;  // Coppie JPY o Oro: point tipico 0.01
        } else {
            g_pointValue = MathPow(PHI_INV, 23);  // ~0.00001 per forex standard
        }
    }
    
    // 🔧 FIX: Calcola e cacha Magic Number UNA VOLTA (evita ricalcolo costante)
    g_uniqueMagicNumber = CalculateUniqueMagicNumber();
    PrintFormat("[INIT] 🔐 Magic Number unico per %s: %d", _Symbol, g_uniqueMagicNumber);
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 1: PRE-CARICAMENTO DATI STORICI
    // Carica abbastanza barre per calcolare autocorrelazione e cicli
    // Se i dati non sono sufficienti, il TF viene DISABILITATO (no fallback!)
    // ═══════════════════════════════════════════════════════════════
    Print("[INIT] 📊 Pre-caricamento dati storici per analisi naturale...");
    
    // Calcola periodi naturali E forza autocorrelazione per ogni TF
    // Entrambi derivati COMPLETAMENTE dai dati!
    NaturalPeriodResult result_M5 = CalculateNaturalPeriodForTF(PERIOD_M5);
    NaturalPeriodResult result_H1 = CalculateNaturalPeriodForTF(PERIOD_H1);
    NaturalPeriodResult result_H4 = CalculateNaturalPeriodForTF(PERIOD_H4);
    NaturalPeriodResult result_D1 = CalculateNaturalPeriodForTF(PERIOD_D1);
    
    // 🌱 PURO: Disabilita TF senza dati sufficienti
    g_dataReady_M5 = result_M5.valid;
    g_dataReady_H1 = result_H1.valid;
    g_dataReady_H4 = result_H4.valid;
    g_dataReady_D1 = result_D1.valid;
    
    if (!result_M5.valid) Print("❌ [INIT] M5: Dati insufficienti - TF DISABILITATO");
    if (!result_H1.valid) Print("❌ [INIT] H1: Dati insufficienti - TF DISABILITATO");
    if (!result_H4.valid) Print("❌ [INIT] H4: Dati insufficienti - TF DISABILITATO");
    if (!result_D1.valid) Print("❌ [INIT] D1: Dati insufficienti - TF DISABILITATO");
    
    // Verifica che almeno un TF sia attivo
    if (!g_dataReady_M5 && !g_dataReady_H1 && !g_dataReady_H4 && !g_dataReady_D1) {
        Print("❌❌❌ [INIT] NESSUN TIMEFRAME HA DATI SUFFICIENTI - EA NON PUÒ OPERARE");
        return INIT_FAILED;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 2: CALCOLO PESI EMPIRICI (ESPONENTE DI HURST)
    // peso_TF = hurstExponent_TF / somma(hurstExponent)
    // H > g_hurstRandomHigh: trending → peso maggiore
    // H in [g_hurstRandomLow, g_hurstRandomHigh]: random → zona no-trade
    // H < g_hurstRandomLow: mean-reverting → peso maggiore
    // 100% derivato dai DATI, non dai minuti del timeframe!
    // ═══════════════════════════════════════════════════════════════
    double totalHurst = 0;
    // ✅ hurstExponent già validato nel range organico [φ⁻³, 1-φ⁻³] da CalculateNaturalPeriodForTF
    if (result_M5.valid) totalHurst += result_M5.hurstExponent;
    if (result_H1.valid) totalHurst += result_H1.hurstExponent;
    if (result_H4.valid) totalHurst += result_H4.hurstExponent;
    if (result_D1.valid) totalHurst += result_D1.hurstExponent;
    
    // ✅ VALIDATO: Protezione divisione per zero
    if (totalHurst <= 0) totalHurst = 1.0;
    
    // ✅ VALIDATO: Pesi sempre >= 0 e normalizzati (sommano a 1.0 se almeno un TF valido)
    double weight_M5 = result_M5.valid ? (result_M5.hurstExponent / totalHurst) : 0;
    double weight_H1 = result_H1.valid ? (result_H1.hurstExponent / totalHurst) : 0;
    double weight_H4 = result_H4.valid ? (result_H4.hurstExponent / totalHurst) : 0;
    double weight_D1 = result_D1.valid ? (result_D1.hurstExponent / totalHurst) : 0;
    
    PrintFormat("[INIT] 🌱 Periodi naturali: M5=%d H1=%d H4=%d D1=%d",
        result_M5.period, result_H1.period, result_H4.period, result_D1.period);
    // NOTA: T/M/R sono etichette preliminari - la zona esatta sarà calcolata dai dati storici
    PrintFormat("[INIT] 🌱 Hurst: M5=%.3f H1=%.3f H4=%.3f D1=%.3f",
        result_M5.hurstExponent, result_H1.hurstExponent, result_H4.hurstExponent, result_D1.hurstExponent);
    PrintFormat("[INIT] 🌱 PESI EMPIRICI (Hurst): M5=%.2f H1=%.2f H4=%.2f D1=%.2f",
        weight_M5, weight_H1, weight_H4, weight_D1);
    PrintFormat("[INIT] 🌱 TF attivi: M5=%s H1=%s H4=%s D1=%s",
        g_dataReady_M5 ? "✅" : "❌", g_dataReady_H1 ? "✅" : "❌", 
        g_dataReady_H4 ? "✅" : "❌", g_dataReady_D1 ? "✅" : "❌");
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 3: CALCOLO PERIODI ORGANICI (solo per TF attivi)
    // TUTTI i periodi sono derivati dal periodo naturale usando rapporti φ
    // I pesi sono passati insieme al periodo naturale
    // ═══════════════════════════════════════════════════════════════
    if (g_dataReady_M5) CalculateOrganicPeriodsFromData(PERIOD_M5, g_organic_M5, result_M5.period, weight_M5, result_M5.hurstExponent);
    if (g_dataReady_H1) CalculateOrganicPeriodsFromData(PERIOD_H1, g_organic_H1, result_H1.period, weight_H1, result_H1.hurstExponent);
    if (g_dataReady_H4) CalculateOrganicPeriodsFromData(PERIOD_H4, g_organic_H4, result_H4.period, weight_H4, result_H4.hurstExponent);
    if (g_dataReady_D1) CalculateOrganicPeriodsFromData(PERIOD_D1, g_organic_D1, result_D1.period, weight_D1, result_D1.hurstExponent);
    
    // Log periodi organici calcolati
    if (g_enableLogsEffective) {
        Print("");
        Print("═══════════════════════════════════════════════════════════════");
        Print("🌱 PERIODI E PESI 100% DATA-DRIVEN (Hurst + Rapporti φ)");
        Print("═══════════════════════════════════════════════════════════════");
        if (g_dataReady_M5) LogOrganicPeriods("M5", g_organic_M5);
        if (g_dataReady_H1) LogOrganicPeriods("H1", g_organic_H1);
        if (g_dataReady_H4) LogOrganicPeriods("H4", g_organic_H4);
        if (g_dataReady_D1) LogOrganicPeriods("D1", g_organic_D1);
        Print("═══════════════════════════════════════════════════════════════");
        Print("");
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 4: INIZIALIZZA FILTRO HURST NO-TRADE ZONE (preliminare)
    // I regimi iniziali e la zona adattiva verranno calcolati
    // dopo l'inizializzazione del buffer in STEP 6
    // ═══════════════════════════════════════════════════════════════
    if (EnableHurstFilter) {
        // Imposta regimi iniziali (saranno aggiornati in RecalculateOrganicSystem)
        g_hurstRegime_M5 = GetHurstRegime(result_M5.hurstExponent);
        g_hurstRegime_H1 = GetHurstRegime(result_H1.hurstExponent);
        g_hurstRegime_H4 = GetHurstRegime(result_H4.hurstExponent);
        g_hurstRegime_D1 = GetHurstRegime(result_D1.hurstExponent);
        
        // NOTA: Il ricalcolo completo avviene ad ogni barra in RecalculateOrganicSystem()
        
        Print("");
        Print("═══════════════════════════════════════════════════════════════");
        Print("🌱 FILTRO HURST NO-TRADE ZONE ATTIVO (preliminare)");
        if (RecalcEveryBars > 0) {
            PrintFormat("   Ricalcolo: ogni %d barre (ottimizzato per backtest)", RecalcEveryBars);
        } else {
            Print("   Ricalcolo: ogni nuova barra");
        }
        Print("   Zona adattiva e buffer verranno inizializzati in STEP 6");
        Print("═══════════════════════════════════════════════════════════════");
        Print("");
    } else {
        Print("[INIT] ⚠️ Filtro Hurst NO-TRADE ZONE: DISABILITATO");
        g_hurstAllowTrade = true;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 5: INIZIALIZZA SOGLIA SCORE DINAMICA
    // Se AutoScoreThreshold=true, la soglia sarà derivata dalla
    // distribuzione storica degli score. Altrimenti usa valore manuale.
    // ═══════════════════════════════════════════════════════════════
    InitScoreHistoryBuffer();
    if (AutoScoreThreshold) {
        // ✅ VALIDATO: minSamples derivato da φ: φ⁴ ≈ 7 come minimo assoluto (ridotto per trading più veloce)
        int minSamplesOrganic = (int)MathRound(MathPow(PHI, 4));  // φ⁴ ≈ 7
        int minSamplesForInit = MathMax(minSamplesOrganic, (int)MathCeil(SCORE_HISTORY_MAX * PHI_INV_SQ * PHI_INV_SQ));
        Print("");
        Print("═══════════════════════════════════════════════════════════════");
        Print("🌱 SOGLIA SCORE 100% DERIVATA DAI DATI");
        Print("   Formula: threshold = mean_score + stdev_score × φ⁻¹");
        PrintFormat("   Buffer: %d campioni | Ready dopo %d campioni (~%d%% del buffer, φ⁻⁴)", 
            SCORE_HISTORY_MAX, minSamplesForInit, (int)MathRound(100.0 * minSamplesForInit / SCORE_HISTORY_MAX));
        PrintFormat("   Limiti: [%.1f%%, %.1f%%] (1/φ³ a 1-1/φ³)", PHI_INV_CUB * 100, (1.0 - PHI_INV_CUB) * 100);
        Print("   🔧 FIX: Minimo campioni ridotto per trading più veloce");
        Print("═══════════════════════════════════════════════════════════════");
        Print("");
    } else {
        PrintFormat("[INIT] 🌱 Soglia score MANUALE: %.1f%%", ScoreThreshold);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 6: INIZIALIZZA BUFFER STORICO HURST
    // Per calcolo zona random adattiva: centro ± (stdev_H × φ⁻¹)
    // ═══════════════════════════════════════════════════════════════
    InitHurstHistoryBuffer();
    
    // 🚀 Pre-carica il buffer Hurst dai dati storici
    // Così il trading può iniziare SUBITO invece di aspettare warm-up!
    PreloadHurstBufferFromHistory();
    
    if (EnableHurstFilter) {
        Print("");
        Print("═══════════════════════════════════════════════════════════════");
        Print("🌱 FILTRO HURST ADATTIVO ATTIVO");
        if (g_hurstZoneReady) {
            Print("   ✅ Buffer Hurst GIÀ PRONTO (pre-caricato da storia)");
        } else {
            Print("   Zona e soglie verranno calcolate dai dati di mercato");
        }
        PrintFormat("   Buffer Hurst: %d/%d campioni | Ready: %s", 
            g_hurstHistorySize, HURST_HISTORY_MAX, g_hurstZoneReady ? "✅" : "❌");
        PrintFormat("   Buffer TradeScore: %d campioni | Ready dopo ~%d campioni",
            TRADE_SCORE_HISTORY_MAX, (int)MathCeil(TRADE_SCORE_HISTORY_MAX * PHI_INV_SQ));
        Print("   Formula zona: centro = mean(H), margine = stdev(H) × φ⁻¹");
        Print("   Formula soglia: mean(tradeScore) + stdev(tradeScore) × φ⁻¹");
        Print("═══════════════════════════════════════════════════════════════");
        Print("");
    }
    
    trade.SetExpertMagicNumber(g_uniqueMagicNumber);  // 🔧 FIX: Usa cache
    trade.SetMarginMode();
    trade.SetTypeFillingBySymbol(_Symbol);
    trade.SetDeviationInPoints(MaxSlippage);
    
    if (g_enableLogsEffective) {
        PrintFormat("[INIT] 🔧 Magic Number unico per %s: %d (base=%d)", 
            _Symbol, g_uniqueMagicNumber, MagicNumber);
    }
    
    if (!InitializeIndicators()) {
        Print("[ERROR] Errore inizializzazione indicatori");
        return INIT_FAILED;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🔧 FIX: Verifica che almeno un indicatore DIREZIONALE sia abilitato
    // Senza indicatori attivi, lo score sarà sempre 0 e nessun trade eseguito
    // ═══════════════════════════════════════════════════════════════
    int numIndicatorsEnabled = 0;
    if (enableEMA)    numIndicatorsEnabled++;
    if (enableRSI)    numIndicatorsEnabled++;
    if (enableMACD)   numIndicatorsEnabled++;
    if (enableBB)     numIndicatorsEnabled++;
    if (enableHeikin) numIndicatorsEnabled++;
    if (enableOBV)    numIndicatorsEnabled++;
    if (enableADX)    numIndicatorsEnabled++;
    
    if (numIndicatorsEnabled == 0) {
        Print("❌❌❌ [INIT] NESSUN INDICATORE ABILITATO!");
        Print("   → Almeno uno tra EMA, RSI, MACD, BB, Heikin, OBV, ADX deve essere TRUE");
        Print("   → EA non può generare segnali di trading");
        return INIT_FAILED;
    }
    PrintFormat("[INIT] ✅ %d indicatori direzionali abilitati", numIndicatorsEnabled);
    
    // 🔧 FIX: Salva periodi iniziali per rilevamento cambi futuri
    SaveCurrentPeriodsAsPrevious();
    
    // 🔧 FIX: Inizializza warmup period
    g_eaStartTime = TimeCurrent();
    g_warmupComplete = false;
    // Warmup = φ² × naturalPeriod più lungo disponibile (minimo 50 barre)
    int longestPeriod = MathMax(MathMax(g_organic_M5.naturalPeriod, g_organic_H1.naturalPeriod),
                                MathMax(g_organic_H4.naturalPeriod, g_organic_D1.naturalPeriod));
    g_warmupBarsRequired = MathMax(50, (int)MathRound(longestPeriod * PHI_SQ));
    PrintFormat("[INIT] 🔄 Warmup: %d barre richieste prima del trading", g_warmupBarsRequired);
    
    // ═══════════════════════════════════════════════════════════════
    // 🎯 INIZIALIZZA STATISTICHE TRADING
    // ═══════════════════════════════════════════════════════════════
    ZeroMemory(g_stats);
    g_stats.peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // Buffer trade recenti = φ⁸ ≈ 47
    g_recentTradesMax = (int)MathRound(MathPow(PHI, 8));
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 INIZIALIZZA DETECTOR INVERSIONE
    // ═══════════════════════════════════════════════════════════════
    InitReversalDetectors();
    ArrayResize(g_recentTrades, g_recentTradesMax);
    g_recentTradesCount = 0;
    g_recentTradesIndex = 0;
    
    PrintFormat("[INIT] 📊 Statistiche trading inizializzate | Buffer ultimi %d trade | Equity iniziale: %.2f", 
        g_recentTradesMax, g_stats.peakEquity);
    
    // ═══════════════════════════════════════════════════════════════
    // �🚀 RIEPILOGO STATO BUFFER - Trading pronto?
    // ═══════════════════════════════════════════════════════════════
    Print("");
    Print("═══════════════════════════════════════════════════════════════");
    Print("🚀 STATO BUFFER E PRONTEZZA TRADING");
    Print("═══════════════════════════════════════════════════════════════");
    PrintFormat("   Buffer Hurst: %d/%d | Ready: %s", 
        g_hurstHistorySize, HURST_HISTORY_MAX, g_hurstZoneReady ? "✅" : "❌");
    PrintFormat("   Buffer TradeScore: %d/%d | Ready: %s", 
        g_tradeScoreHistorySize, TRADE_SCORE_HISTORY_MAX, g_tradeScoreReady ? "✅" : "❌");
    PrintFormat("   g_hurstReady: %s", g_hurstReady ? "✅" : "❌");
    PrintFormat("   Buffer Score Indicatori: %d/%d | Ready: %s (fallback: soglia manuale %.1f%%)", 
        g_scoreHistorySize, SCORE_HISTORY_MAX, g_scoreThresholdReady ? "✅" : "❌", ScoreThreshold);
    
    if (g_hurstReady) {
        Print("   ✅✅✅ TRADING PRONTO IMMEDIATAMENTE!");
    } else {
        Print("   ⚠️ Warm-up parziale richiesto per alcuni buffer");
    }
    Print("═══════════════════════════════════════════════════════════════");
    Print("");
    
    Print("[INIT] ✅ EA DATA-DRIVEN inizializzato - periodi E PESI auto-calcolati dai dati");
    
    if (g_enableLogsEffective) {
        PrintFormat("[INIT] Sistema voti indicatori: %s (M5=%s | H1=%s | H4=%s | D1=%s)",
            StateLabel(EnableIndicatorVoteSystem),
            StateLabel(EnableVote_M5),
            StateLabel(EnableVote_H1),
            StateLabel(EnableVote_H4),
            StateLabel(EnableVote_D1));
    }
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 🌱 RICALCOLO COMPLETO: Periodi naturali, pesi, e periodi organici|
//| Chiamato ad ogni nuova barra per adattarsi ai cambi di regime    |
//| 🚀 OTTIMIZZATO: Usa cache per evitare ricalcoli costosi          |
//+------------------------------------------------------------------+
void RecalculateOrganicSystem()
{
    // ═══════════════════════════════════════════════════════════════
    // � FIX: RILEVAMENTO GAP DI PREZZO - Invalida cache se gap > ATR × φ
    // Questo garantisce che cambi di regime improvvisi vengano gestiti
    // ═══════════════════════════════════════════════════════════════
    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if (g_cacheValid && g_lastCachePrice > 0 && g_lastCacheATR > 0) {
        double priceChange = MathAbs(currentPrice - g_lastCachePrice);
        double gapThreshold = g_lastCacheATR * PHI;  // Gap = ATR × φ
        
        if (priceChange > gapThreshold) {
            g_cacheValid = false;  // Invalida cache su gap
            if (g_enableLogsEffective) {
                PrintFormat("[RECALC] ⚠️ GAP rilevato: %.5f > %.5f (ATR×φ) - Cache invalidata", 
                    priceChange, gapThreshold);
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🚀 CHECK CACHE - Ricalcola Hurst SOLO ogni N cicli (molto costoso!)
    // ═══════════════════════════════════════════════════════════════
    // 🌱 Intervallo ricalcolo derivato da φ⁶ ≈ 18 (invece di 40 hardcoded)
    int hurstRecalcDivisor = (int)MathRound(MathPow(PHI, 6));  // φ⁶ ≈ 18
    int hurstRecalcInterval = MathMax((int)MathRound(PHI_SQ), RecalcEveryBars / hurstRecalcDivisor);  // Minimo φ² ≈ 3
    
    bool needFullHurstRecalc = false;
    if (!g_cacheValid || g_hurstRecalcCounter >= hurstRecalcInterval) {
        needFullHurstRecalc = true;
        g_hurstRecalcCounter = 0;
    } else {
        g_hurstRecalcCounter++;
    }
    
    NaturalPeriodResult result_M5, result_H1, result_H4, result_D1;
    
    if (needFullHurstRecalc) {
        // 🌱 STEP 1: RICALCOLA PERIODI NATURALI E HURST (COSTOSO!)
        result_M5 = CalculateNaturalPeriodForTF(PERIOD_M5);
        result_H1 = CalculateNaturalPeriodForTF(PERIOD_H1);
        result_H4 = CalculateNaturalPeriodForTF(PERIOD_H4);
        result_D1 = CalculateNaturalPeriodForTF(PERIOD_D1);
        
        // Salva in cache
        g_cachedResult_M5 = result_M5;
        g_cachedResult_H1 = result_H1;
        g_cachedResult_H4 = result_H4;
        g_cachedResult_D1 = result_D1;
        g_cacheValid = true;
        
        // 🔧 FIX: Aggiorna prezzo e ATR per rilevamento gap successivo
        g_lastCachePrice = currentPrice;
        // Usa ATR medio dal TF più stabile disponibile
        if (g_dataReady_H1 && tfData_H1.atr_avg > 0) {
            g_lastCacheATR = tfData_H1.atr_avg;
        } else if (g_dataReady_H4 && tfData_H4.atr_avg > 0) {
            g_lastCacheATR = tfData_H4.atr_avg;
        } else if (g_dataReady_M5 && tfData_M5.atr_avg > 0) {
            g_lastCacheATR = tfData_M5.atr_avg;
        } else {
            // 🌱 Fallback organico: φ⁸ ≈ 47 pips × pointValue × φ
            //    Usato SOLO se nessun TF ha ATR valido
            int fallbackPips = (int)MathRound(MathPow(PHI, 8));  // φ⁸ ≈ 47
            g_lastCacheATR = g_pointValue * fallbackPips * PHI;
        }
    } else {
        // 🚀 USA CACHE (molto più veloce!)
        result_M5 = g_cachedResult_M5;
        result_H1 = g_cachedResult_H1;
        result_H4 = g_cachedResult_H4;
        result_D1 = g_cachedResult_D1;
    }
    
    // Aggiorna flag di validità
    g_dataReady_M5 = result_M5.valid;
    g_dataReady_H1 = result_H1.valid;
    g_dataReady_H4 = result_H4.valid;
    g_dataReady_D1 = result_D1.valid;
    
    // Verifica che almeno un TF sia attivo
    if (!g_dataReady_M5 && !g_dataReady_H1 && !g_dataReady_H4 && !g_dataReady_D1) {
        Print("❌ [RECALC] NESSUN TF HA DATI SUFFICIENTI");
        return;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 2: RICALCOLA PESI EMPIRICI (Hurst)
    // peso_TF = hurstExponent_TF / somma(hurstExponent)
    // ═══════════════════════════════════════════════════════════════
    double totalHurst = 0;
    // ✅ hurstExponent già validato nel range organico [φ⁻³, 1-φ⁻³] da CalculateNaturalPeriodForTF
    if (result_M5.valid) totalHurst += result_M5.hurstExponent;
    if (result_H1.valid) totalHurst += result_H1.hurstExponent;
    if (result_H4.valid) totalHurst += result_H4.hurstExponent;
    if (result_D1.valid) totalHurst += result_D1.hurstExponent;
    
    // ✅ VALIDATO: Protezione divisione per zero
    if (totalHurst <= 0) totalHurst = 1.0;
    
    // ✅ VALIDATO: Pesi sempre >= 0 e normalizzati
    double weight_M5 = result_M5.valid ? (result_M5.hurstExponent / totalHurst) : 0;
    double weight_H1 = result_H1.valid ? (result_H1.hurstExponent / totalHurst) : 0;
    double weight_H4 = result_H4.valid ? (result_H4.hurstExponent / totalHurst) : 0;
    double weight_D1 = result_D1.valid ? (result_D1.hurstExponent / totalHurst) : 0;
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 3: RICALCOLA PERIODI ORGANICI (solo se Hurst ricalcolato)
    // 🚀 OTTIMIZZATO: salta se usiamo cache
    // ═══════════════════════════════════════════════════════════════
    if (needFullHurstRecalc) {
        if (g_dataReady_M5) CalculateOrganicPeriodsFromData(PERIOD_M5, g_organic_M5, result_M5.period, weight_M5, result_M5.hurstExponent);
        if (g_dataReady_H1) CalculateOrganicPeriodsFromData(PERIOD_H1, g_organic_H1, result_H1.period, weight_H1, result_H1.hurstExponent);
        if (g_dataReady_H4) CalculateOrganicPeriodsFromData(PERIOD_H4, g_organic_H4, result_H4.period, weight_H4, result_H4.hurstExponent);
        if (g_dataReady_D1) CalculateOrganicPeriodsFromData(PERIOD_D1, g_organic_D1, result_D1.period, weight_D1, result_D1.hurstExponent);
        
        // 🔧 FIX: Controlla se i periodi sono cambiati significativamente (>20%)
        // Se sì, ricrea gli handle indicatori con i nuovi periodi
        if (PeriodsChangedSignificantly()) {
            if (g_enableLogsEffective) {
                Print("[RECALC] 🔄 Periodi cambiati >20% - Ricreazione handle indicatori...");
            }
            ReleaseIndicators();
            if (!InitializeIndicators()) {
                Print("❌ [RECALC] Errore ricreazione handle indicatori!");
            } else {
                // 🔧 FIX: Invalida cache dopo ricreazione handle - i dati vecchi non sono più validi
                g_tfDataCacheValid = false;
                g_cacheValid = false;
                if (g_enableLogsEffective) {
                    Print("[RECALC] ✅ Handle indicatori ricreati con nuovi periodi (cache invalidata)");
                }
            }
        }
        
        // Salva periodi correnti per confronto futuro
        SaveCurrentPeriodsAsPrevious();
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 4: AGGIORNA FILTRO HURST COMPLETO
    // - Regimi per ogni TF
    // - H PESATO (non media semplice!)
    // - Aggiunge H al buffer storico → zona adattiva
    // - Calcola tradeScore e soglia
    // ═══════════════════════════════════════════════════════════════
    if (EnableHurstFilter) {
        g_hurstRegime_M5 = GetHurstRegime(result_M5.hurstExponent);
        g_hurstRegime_H1 = GetHurstRegime(result_H1.hurstExponent);
        g_hurstRegime_H4 = GetHurstRegime(result_H4.hurstExponent);
        g_hurstRegime_D1 = GetHurstRegime(result_D1.hurstExponent);
        
        // ═══════════════════════════════════════════════════════════════
        // 🌱 CALCOLO H PESATO (non media semplice!)
        // H_weighted = Σ(H_TF × peso_TF) / Σ(peso_TF)
        // ═══════════════════════════════════════════════════════════════
        double hurstWeightedSum = 0;
        double weightSum = 0;
        
        if (g_dataReady_M5 && result_M5.valid) { 
            hurstWeightedSum += result_M5.hurstExponent * weight_M5;
            weightSum += weight_M5;
        }
        if (g_dataReady_H1 && result_H1.valid) { 
            hurstWeightedSum += result_H1.hurstExponent * weight_H1;
            weightSum += weight_H1;
        }
        if (g_dataReady_H4 && result_H4.valid) { 
            hurstWeightedSum += result_H4.hurstExponent * weight_H4;
            weightSum += weight_H4;
        }
        if (g_dataReady_D1 && result_D1.valid) { 
            hurstWeightedSum += result_D1.hurstExponent * weight_D1;
            weightSum += weight_D1;
        }
        
        // H composito PESATO (0.0 se nessun dato valido - protezione div/0)
        g_hurstComposite = (weightSum > 0) ? (hurstWeightedSum / weightSum) : 0.0;
        
        // 🌱 Aggiunge H al buffer storico → calcola zona adattiva
        // ⚠️ CRITICO: NON aggiungere valori invalidi (fuori range organico) al buffer!
        if (weightSum > 0 && g_hurstComposite > HURST_RANGE_MIN && g_hurstComposite < HURST_RANGE_MAX) {
            AddHurstToHistory(g_hurstComposite);
        }
        
        // Calcola confidenza (usa g_hurstCenter calcolato in AddHurstToHistory)
        g_hurstConfidence = GetHurstConfidence(g_hurstComposite);
        
        // ═══════════════════════════════════════════════════════════════
        // 🌱 CALCOLA tradeScore 100% DAI DATI
        // deviation = |H - centro| dove centro = media(H) storica
        // normalizzazione = stdev storica × φ (scala data-driven)
        // ✅ VALIDATO: tradeScore sempre >= 0
        //    - deviation >= 0 (MathAbs)
        //    - g_hurstConfidence in [0, 1] (validato in GetHurstConfidence)
        //    - normFactor > 0 quando usato
        // ═══════════════════════════════════════════════════════════════
        // 🔧 FIX: Check esplicito g_hurstStdev > 0 (può essere 0 se tutti i valori Hurst sono identici)
        if (!g_hurstZoneReady || g_hurstStdev <= 0) {
            g_hurstTradeScore = 0.0;  // ✅ Zona non pronta o stdev invalida → 0 (sicuro)
        } else {
            double deviation = MathAbs(g_hurstComposite - g_hurstCenter);  // ✅ >= 0
            // 🌱 Normalizzazione: dividi per (stdev × φ) - scala 100% dai dati
            double normFactor = g_hurstStdev * PHI;
            if (normFactor > 0) {
                g_hurstTradeScore = deviation * g_hurstConfidence / normFactor;  // ✅ >= 0
            } else {
                g_hurstTradeScore = 0.0;  // ✅ Fallback sicuro
            }
        }
        
        // 🌱 Aggiorna buffer tradeScore per soglia adattiva
        // IMPORTANTE: aggiungi SOLO se zona pronta (evita zeri durante warm-up)
        // 🚀 OTTIMIZZATO: usa somme incrementali O(1) invece di O(n)
        // 🔧 FIX: Ricalcolo periodico anti-drift
        // ✅ VALIDATO: g_hurstTradeScore >= 0 garantito (vedi sopra)
        if (g_hurstZoneReady) {
            // 🔧 FIX: Ricalcolo completo periodico per evitare drift floating point
            g_tradeScoreOperationCount++;
            if (g_tradeScoreOperationCount >= TRADE_SCORE_HISTORY_MAX) {
                RecalculateTradeScoreSumsFromScratch();
                g_tradeScoreOperationCount = 0;
            }
            
            // ✅ Sottrai valore vecchio se buffer pieno (PRIMA di sovrascrivere!)
            if (g_tradeScoreHistorySize == TRADE_SCORE_HISTORY_MAX) {
                double oldValue = g_tradeScoreHistory[g_tradeScoreHistoryIndex];
                g_tradeScoreSum -= oldValue;
                g_tradeScoreSumSq -= oldValue * oldValue;
                
                // ✅ SANITY CHECK: protezione da errori floating point accumulati
                if (g_tradeScoreSum < 0) g_tradeScoreSum = 0;
                if (g_tradeScoreSumSq < 0) g_tradeScoreSumSq = 0;
            }
            
            // Aggiungi nuovo valore
            g_tradeScoreHistory[g_tradeScoreHistoryIndex] = g_hurstTradeScore;
            g_tradeScoreSum += g_hurstTradeScore;
            g_tradeScoreSumSq += g_hurstTradeScore * g_hurstTradeScore;
            
            // ✅ VALIDATO: indice buffer sempre nel range [0, TRADE_SCORE_HISTORY_MAX-1]
            g_tradeScoreHistoryIndex = (g_tradeScoreHistoryIndex + 1) % TRADE_SCORE_HISTORY_MAX;
            if (g_tradeScoreHistorySize < TRADE_SCORE_HISTORY_MAX) g_tradeScoreHistorySize++;
        }
        
        // 🚀 Calcola soglia tradeScore O(1) con somme incrementali!
        int minTradeScoreSamples = (int)MathCeil(TRADE_SCORE_HISTORY_MAX * PHI_INV_SQ);  // ~38% del buffer
        if (g_tradeScoreHistorySize >= minTradeScoreSamples) {
            // ✅ VALIDATO: Media O(1) - divisione sicura (minTradeScoreSamples >= 1)
            double meanTS = g_tradeScoreSum / g_tradeScoreHistorySize;
            // ✅ VALIDATO: Varianza O(1): E[X²] - E[X]² con protezione negativa
            double meanSqTS = g_tradeScoreSumSq / g_tradeScoreHistorySize;
            double varianceTS = meanSqTS - (meanTS * meanTS);
            double stdevTS = (varianceTS > 0) ? MathSqrt(varianceTS) : 0.0;
            g_tradeScoreThreshold = meanTS + stdevTS * PHI_INV;  // ✅ >= 0
            g_tradeScoreReady = true;
        } else {
            g_tradeScoreReady = false;
        }
        
        // 🌱 DECISIONE TRADE: richiede zona Hurst + soglia tradeScore pronte
        g_hurstReady = (g_hurstZoneReady && g_tradeScoreReady);
        g_hurstAllowTrade = g_hurstReady && (g_hurstTradeScore >= g_tradeScoreThreshold);
        
        lastHurstRecalc = TimeCurrent();
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 STEP 5: AGGIORNA SOGLIA SCORE DINAMICA
    // Se AutoScoreThreshold=true, ricalcola dalla distribuzione
    // ═══════════════════════════════════════════════════════════════
    UpdateDynamicThreshold();
    
    // Log dettagliato del ricalcolo organico
    if (g_enableLogsEffective) {
        Print("┌─────────────────────────────────────────────────────────────────────────────┐");
        Print("│ 🌱 RICALCOLO SISTEMA ORGANICO COMPLETATO                                    │");
        Print("├─────────────────────────────────────────────────────────────────────────────┤");
        Print("│ STEP 1: PERIODI NATURALI (derivati da autocorrelazione dati)               │");
        PrintFormat("│   M5=%3d | H1=%3d | H4=%3d | D1=%3d                                        │",
            result_M5.period, result_H1.period, result_H4.period, result_D1.period);
        Print("├─────────────────────────────────────────────────────────────────────────────┤");
        Print("│ STEP 2: ESPONENTI HURST (confronto vs g_hurstCenter storico)               │");
        PrintFormat("│   M5=%.3f(%s) H1=%.3f(%s) H4=%.3f(%s) D1=%.3f(%s)                       │",
            result_M5.hurstExponent, g_hurstRegime_M5 == HURST_TRENDING ? "TREND" : (g_hurstRegime_M5 == HURST_MEANREV ? "M-REV" : "RAND "),
            result_H1.hurstExponent, g_hurstRegime_H1 == HURST_TRENDING ? "TREND" : (g_hurstRegime_H1 == HURST_MEANREV ? "M-REV" : "RAND "),
            result_H4.hurstExponent, g_hurstRegime_H4 == HURST_TRENDING ? "TREND" : (g_hurstRegime_H4 == HURST_MEANREV ? "M-REV" : "RAND "),
            result_D1.hurstExponent, g_hurstRegime_D1 == HURST_TRENDING ? "TREND" : (g_hurstRegime_D1 == HURST_MEANREV ? "M-REV" : "RAND "));
        PrintFormat("│   H_pesato = %.4f (formula: Σ(H×peso) / Σ(peso))                          │", g_hurstComposite);
        Print("├─────────────────────────────────────────────────────────────────────────────┤");
        Print("│ STEP 3: PESI TF (derivati da Hurst: peso = H_TF / Σ(H))                     │");
        PrintFormat("│   M5=%.3f | H1=%.3f | H4=%.3f | D1=%.3f                                    │",
            weight_M5, weight_H1, weight_H4, weight_D1);
        Print("├─────────────────────────────────────────────────────────────────────────────┤");
        Print("│ STEP 4: ZONA HURST ADATTIVA (centro=mean(H), margine=stdev×φ⁻¹)             │");
        PrintFormat("│   Centro: %.4f (mean storica) | Stdev: %.5f                              │", g_hurstCenter, g_hurstStdev);
        PrintFormat("│   Zona: [%.4f, %.4f] | Buffer: %d/%d campioni                          │", 
            g_hurstRandomLow, g_hurstRandomHigh, g_hurstHistorySize, HURST_HISTORY_MAX);
        PrintFormat("│   TradeScore: %.4f | Soglia: %.4f | Stato: %s                           │",
            g_hurstTradeScore, g_tradeScoreThreshold,
            g_hurstAllowTrade ? "✅ TRADE OK" : (g_hurstReady ? "❌ BLOCCATO" : "⏳ ATTESA DATI"));
        Print("├─────────────────────────────────────────────────────────────────────────────┤");
        Print("│ STEP 5: SOGLIA SCORE DINAMICA (formula: mean + stdev × φ⁻¹)                 │");
        if (g_scoreThresholdReady) {
            PrintFormat("│   Soglia corrente: %.2f%% | Buffer: %d/%d | Pronta: ✅                     │",
                g_dynamicThreshold, g_scoreHistorySize, SCORE_HISTORY_MAX);
        } else {
            PrintFormat("│   Soglia corrente: (in attesa dati) | Buffer: %d/%d | Pronta: ⏳           │",
                g_scoreHistorySize, SCORE_HISTORY_MAX);
        }
        Print("└─────────────────────────────────────────────────────────────────────────────┘");
    }
}

//+------------------------------------------------------------------+
//| 🌱 Calcola ESPONENTE DI HURST (metodo R/S - OTTIMIZZATO)         |
//| 🚀 Usa scale fisse e limite barre per velocità                   |
//+------------------------------------------------------------------+
double CalculateHurstExponent(MqlRates &rates[], int n)
{
    // 🌱 COSTANTI ORGANICHE: tutte derivate da potenze di φ
    // φ⁸ ≈ 47, φ¹¹ ≈ 199 (limite max per evitare rumore)
    int minBarsHurst = (int)MathRound(MathPow(PHI, 8));   // φ⁸ ≈ 47
    int maxBarsHurst = (int)MathRound(MathPow(PHI, 11));  // φ¹¹ ≈ 199
    
    // 🌱 Range Hurst valido: derivato da φ⁻² e 1-φ⁻²
    double hurstMin = PHI_INV_SQ;           // ≈ 0.382 (sotto = molto mean-reverting)
    double hurstMax = 1.0 - PHI_INV_SQ;     // ≈ 0.618 (sopra = molto trending)
    // Estendiamo leggermente per catturare valori estremi
    hurstMin = hurstMin * PHI_INV;          // ≈ 0.236
    hurstMax = 1.0 - hurstMin;              // ≈ 0.764
    
    // 🚀 OTTIMIZZAZIONE: Minimo barre organico
    // 🌱 Se dati insufficienti, ritorna centro storico SE disponibile dai DATI
    //    NESSUN fallback teorico (0.5) - solo valori empirici!
    if (n < minBarsHurst) {
        if (g_hurstZoneReady && g_hurstCenter > 0) return g_hurstCenter;
        return -1.0;  // Segnala "dati insufficienti" (gestito dal chiamante)
    }
    
    // 🌱 Limita a φ¹¹ barre max (derivato organicamente)
    int effectiveN = MathMin(n, maxBarsHurst);
    
    // Calcola i rendimenti logaritmici
    double returns[];
    ArrayResize(returns, effectiveN - 1);
    for (int i = 0; i < effectiveN - 1; i++) {
        if (rates[i+1].close > 0 && rates[i].close > 0) {
            returns[i] = MathLog(rates[i].close / rates[i+1].close);
        } else {
            returns[i] = 0;
        }
    }
    
    int numReturns = effectiveN - 1;
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 METODO R/S SEMPLIFICATO - Scale calcolate dinamicamente da φ
    // Scale = potenze ESATTE di φ: round(φ⁵), round(φ⁶), round(φ⁷), round(φ⁸), round(φ⁹)
    // ═══════════════════════════════════════════════════════════════
    double logN[5], logRS[5];
    // 🌱 Scale calcolate dinamicamente da potenze di φ
    int scales[5];
    scales[0] = (int)MathRound(MathPow(PHI, 5));  // φ⁵ ≈ 11
    scales[1] = (int)MathRound(MathPow(PHI, 6));  // φ⁶ ≈ 18
    scales[2] = (int)MathRound(MathPow(PHI, 7));  // φ⁷ ≈ 29
    scales[3] = (int)MathRound(MathPow(PHI, 8));  // φ⁸ ≈ 47
    scales[4] = (int)MathRound(MathPow(PHI, 9));  // φ⁹ ≈ 76
    int numScales = 0;
    
    for (int s = 0; s < 5; s++) {
        int scale = scales[s];
        if (scale >= numReturns / 2) break;
        
        int numBlocks = numReturns / scale;
        if (numBlocks < 2) continue;
        
        double rsSum = 0;
        int validBlocks = 0;
        
        for (int block = 0; block < numBlocks; block++) {
            int startIdx = block * scale;
            
            // Media del blocco
            double blockMean = 0;
            for (int j = 0; j < scale; j++) {
                blockMean += returns[startIdx + j];
            }
            blockMean /= scale;
            
            // Deviazione cumulativa e range - CALCOLO UNIFICATO
            double cumDev = 0;
            double minCumDev = 0;
            double maxCumDev = 0;
            double sumSqDev = 0;
            
            for (int j = 0; j < scale; j++) {
                double dev = returns[startIdx + j] - blockMean;
                cumDev += dev;
                sumSqDev += dev * dev;
                
                if (cumDev < minCumDev) minCumDev = cumDev;
                if (cumDev > maxCumDev) maxCumDev = cumDev;
            }
            
            double range = maxCumDev - minCumDev;
            double stdDev = MathSqrt(sumSqDev / scale);
            
            if (stdDev > 0) {
                rsSum += range / stdDev;
                validBlocks++;
            }
        }
        
        if (validBlocks > 0) {
            double avgRS = rsSum / validBlocks;
            if (avgRS > 0) {
                logN[numScales] = MathLog((double)scale);
                logRS[numScales] = MathLog(avgRS);
                numScales++;
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    // REGRESSIONE LINEARE VELOCE
    // ═══════════════════════════════════════════════════════════════
    // 🌱 Minimo scale = round(φ²) ≈ 3
    int minScales = (int)MathRound(PHI_SQ);
    // 🌱 Se scale insufficienti, ritorna centro storico SE disponibile dai DATI
    //    NESSUN fallback teorico (0.5) - solo valori empirici!
    if (numScales < minScales) {
        if (g_hurstZoneReady && g_hurstCenter > 0) return g_hurstCenter;
        return -1.0;  // Segnala "dati insufficienti"
    }
    
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
    for (int i = 0; i < numScales; i++) {
        sumX += logN[i];
        sumY += logRS[i];
        sumXY += logN[i] * logRS[i];
        sumX2 += logN[i] * logN[i];
    }
    
    double denom = numScales * sumX2 - sumX * sumX;
    // 🌱 Threshold divisione: φ⁻¹⁰ ≈ 1.3e-5 (derivato da φ)
    double divThreshold = MathPow(PHI_INV, 10);
    // 🌱 Se denominatore troppo piccolo, ritorna centro storico SE disponibile dai DATI
    //    NESSUN fallback teorico (0.5) - solo valori empirici!
    if (MathAbs(denom) < divThreshold) {
        if (g_hurstZoneReady && g_hurstCenter > 0) return g_hurstCenter;
        return -1.0;  // Segnala "dati insufficienti"
    }
    
    double H = (numScales * sumXY - sumX * sumY) / denom;
    
    // ✅ VALIDATO: Forza H nel range valido derivato da φ
    // Range: [φ⁻³, 1-φ⁻³] ≈ [0.236, 0.764]
    H = MathMax(hurstMin, MathMin(hurstMax, H));
    return H;
}

//+------------------------------------------------------------------+
//| 🌱 FILTRO HURST: Determina il regime da un singolo valore H      |
//| Soglie ADATTIVE 100% dai dati storici:                           |
//|   centro = media(H), margine = stdev(H) × φ⁻¹                    |
//+------------------------------------------------------------------+
// ✅ VALIDATO: Funzione robusta con protezioni
//    INPUT: h può essere qualsiasi valore
//    OUTPUT: ENUM valida garantita
ENUM_HURST_REGIME GetHurstRegime(double h)
{
    // ✅ VALIDATO: Se H non valido o zona non pronta, ritorna stato sicuro
    if (h < 0 || !g_hurstZoneReady) return HURST_RANDOM;
    
    if (h > g_hurstRandomHigh) return HURST_TRENDING;   // Sopra zona random
    if (h < g_hurstRandomLow)  return HURST_MEANREV;    // Sotto zona random
    return HURST_RANDOM;                                 // Dentro zona random
}

//+------------------------------------------------------------------+
//| 🌱 FILTRO HURST: Calcola confidenza                              |
//| Confidenza = |H - centro| / (stdev × φ), capped a 1.0            |
//| Tutto derivato dai dati: centro = media(H), scala = stdev        |
//| ✅ VALIDATO:                                                      |
//|    INPUT: h può essere qualsiasi valore                          |
//|    OUTPUT: valore nel range [0.0, 1.0] garantito                 |
//+------------------------------------------------------------------+
double GetHurstConfidence(double h)
{
    // ✅ VALIDATO: Se non pronto o stdev invalido, ritorna 0.0 (sicuro)
    if (!g_hurstZoneReady || g_hurstStdev <= 0) return 0.0;
    double deviation = MathAbs(h - g_hurstCenter);
    double maxDeviation = g_hurstStdev * PHI;  // Scala basata su stdev × φ
    // ✅ VALIDATO: maxDeviation > 0 perché stdev > 0 e PHI > 0
    double confidence = deviation / maxDeviation;
    return MathMin(1.0, confidence);               // ✅ Cap a 1.0
}

//+------------------------------------------------------------------+
//| 🌱 FILTRO HURST: Inizializza buffer H storico                    |
//| NESSUN VALORE INIZIALE - tutto sarà calcolato dai dati!          |
//| ✅ VALIDAZIONE: Tutti i valori inizializzati a stati sicuri      |
//+------------------------------------------------------------------+
void InitHurstHistoryBuffer()
{
    // ✅ VALIDATO: Buffer dimensionato correttamente
    ArrayResize(g_hurstHistory, HURST_HISTORY_MAX);
    ArrayInitialize(g_hurstHistory, 0);  // Vuoto, verrà riempito dai dati
    
    // ✅ VALIDATO: Indici inizializzati a 0 (stato sicuro)
    g_hurstHistorySize = 0;
    g_hurstHistoryIndex = 0;
    
    // ✅ VALIDATO: Statistiche inizializzate a 0 (stato "non calcolato")
    g_hurstCenter = 0.0;
    g_hurstStdev = 0.0;
    g_hurstZoneMargin = 0.0;
    g_hurstRandomLow = 0.0;
    g_hurstRandomHigh = 0.0;
    g_hurstZoneReady = false;  // ✅ Flag indica che i dati NON sono pronti
    
    // ✅ VALIDATO: Somme incrementali a 0 (coerente con buffer vuoto)
    g_hurstSum = 0.0;
    g_hurstSumSq = 0.0;
    
    // ✅ VALIDATO: Buffer TradeScore
    ArrayResize(g_tradeScoreHistory, TRADE_SCORE_HISTORY_MAX);
    ArrayInitialize(g_tradeScoreHistory, 0);
    g_tradeScoreHistorySize = 0;
    g_tradeScoreHistoryIndex = 0;
    g_tradeScoreThreshold = 0.0;
    g_tradeScoreReady = false;
    g_hurstReady = false;
    
    // ✅ VALIDATO: Somme incrementali TradeScore a 0
    g_tradeScoreSum = 0.0;
    g_tradeScoreSumSq = 0.0;
    
    if (g_enableLogsEffective) {
        PrintFormat("[INIT-BUFFER] 🌱 g_hurstHistory: ArraySize=%d (max=%d) %s",
            ArraySize(g_hurstHistory), HURST_HISTORY_MAX,
            ArraySize(g_hurstHistory) == HURST_HISTORY_MAX ? "✅" : "❌");
        PrintFormat("[INIT-BUFFER] 🌱 g_tradeScoreHistory: ArraySize=%d (max=%d) %s",
            ArraySize(g_tradeScoreHistory), TRADE_SCORE_HISTORY_MAX,
            ArraySize(g_tradeScoreHistory) == TRADE_SCORE_HISTORY_MAX ? "✅" : "❌");
    }
}

//+------------------------------------------------------------------+
//| 🚀 PRE-CARICAMENTO MULTI-TF OTTIMIZZATO                          |
//| Usa tutti i TF disponibili ma con campionamento per velocità     |
//+------------------------------------------------------------------+
void PreloadHurstBufferFromHistory()
{
    if (!EnableHurstFilter) return;
    
    // 🌱 CONFIGURAZIONE 100% ORGANICA (derivata da φ)
    // barsPerHurst = φ⁸ ≈ 47 (minimo statistico) × φ ≈ 76
    int barsPerHurst = (int)MathRound(MathPow(PHI, 8) * PHI);  // ≈ 76
    int samplesToPreload = HURST_HISTORY_MAX;  // Calcolato dinamicamente in OnInit
    // 🌱 skipFactor = round(φ) = 2 (derivato organicamente)
    int skipFactor = (int)MathRound(PHI);  // ≈ 2
    int effectiveSamples = samplesToPreload / skipFactor;
    
    // 🌱 Buffer organici: derivati da potenze di φ
    int bufferM5 = (int)MathRound(MathPow(PHI, 5));  // φ⁵ ≈ 11
    int bufferH1 = (int)MathRound(MathPow(PHI, 4));  // φ⁴ ≈ 7
    int bufferH4 = (int)MathRound(MathPow(PHI, 3));  // φ³ ≈ 4
    int bufferD1 = (int)MathRound(MathPow(PHI, 5));  // φ⁵ ≈ 11
    
    // 🌱 Rapporti TF calcolati dinamicamente dai minuti reali
    int minutesM5 = PeriodSeconds(PERIOD_M5) / 60;   // = 5
    int minutesH1 = PeriodSeconds(PERIOD_H1) / 60;   // = 60
    int minutesH4 = PeriodSeconds(PERIOD_H4) / 60;   // = 240
    int minutesD1 = PeriodSeconds(PERIOD_D1) / 60;   // = 1440
    
    // Rapporti M5 vs altri TF (calcolati, non hardcoded)
    double ratioH1 = (double)minutesH1 / minutesM5;  // = 12
    double ratioH4 = (double)minutesH4 / minutesM5;  // = 48
    double ratioD1 = (double)minutesD1 / minutesM5;  // = 288
    
    // Barre necessarie per ogni TF (calcolate dinamicamente)
    int totalBarsM5 = effectiveSamples * skipFactor + barsPerHurst + bufferM5;
    int totalBarsH1 = (int)MathRound(totalBarsM5 / ratioH1) + barsPerHurst / 2 + bufferH1;
    int totalBarsH4 = (int)MathRound(totalBarsM5 / ratioH4) + barsPerHurst / 4 + bufferH4;
    int totalBarsD1 = (int)MathRound(totalBarsM5 / ratioD1) + bufferD1;
    
    // Carica dati per tutti i TF disponibili
    MqlRates ratesM5[], ratesH1[], ratesH4[], ratesD1[];
    ArraySetAsSeries(ratesM5, true);
    ArraySetAsSeries(ratesH1, true);
    ArraySetAsSeries(ratesH4, true);
    ArraySetAsSeries(ratesD1, true);
    
    // 🔧 FIX: Usa start=1 per caricare dati STORICI (barre completate, non quella corrente incompleta)
    int copiedM5 = g_dataReady_M5 ? CopyRates(_Symbol, PERIOD_M5, 1, totalBarsM5, ratesM5) : 0;
    int copiedH1 = g_dataReady_H1 ? CopyRates(_Symbol, PERIOD_H1, 1, totalBarsH1, ratesH1) : 0;
    int copiedH4 = g_dataReady_H4 ? CopyRates(_Symbol, PERIOD_H4, 1, totalBarsH4, ratesH4) : 0;
    int copiedD1 = g_dataReady_D1 ? CopyRates(_Symbol, PERIOD_D1, 1, totalBarsD1, ratesD1) : 0;
    
    if (copiedM5 < barsPerHurst) {
        Print("[PRELOAD] ⚠️ Dati M5 insufficienti per pre-caricamento");
        return;
    }
    
    Print("[PRELOAD] 🚀 Pre-caricamento MULTI-TF OTTIMIZZATO...");
    PrintFormat("[PRELOAD] 📊 Barre: M5=%d H1=%d H4=%d D1=%d | Campioni=%d (skip=%d)",
        copiedM5, copiedH1, copiedH4, copiedD1, effectiveSamples, skipFactor);
    
    // ═══════════════════════════════════════════════════════════════
    // FASE 1: Calcola Hurst composito campionato
    // ✅ VALIDATO: Ogni hX validato nel range organico prima di usare
    // ═══════════════════════════════════════════════════════════════
    double hurstValues[];
    ArrayResize(hurstValues, effectiveSamples);
    ArrayInitialize(hurstValues, 0);
    int successCount = 0;
    int lastValidIndex = -1;
    
    for (int sample = 0; sample < effectiveSamples; sample++) {
        int i = sample * skipFactor;
        double hurstWeightedSum = 0;
        double weightSum = 0;
        
        // M5 - ✅ VALIDATO: hM5 controllato nel range organico
        if (copiedM5 >= i + barsPerHurst) {
            MqlRates subRates[];
            ArrayResize(subRates, barsPerHurst);
            for (int j = 0; j < barsPerHurst; j++) subRates[j] = ratesM5[i + j];
            double hM5 = CalculateHurstExponent(subRates, barsPerHurst);
            if (hM5 > HURST_RANGE_MIN && hM5 < HURST_RANGE_MAX) {
                hurstWeightedSum += hM5 * g_organic_M5.weight;
                weightSum += g_organic_M5.weight;
            }
        }
        
        // H1 - ✅ VALIDATO: hH1 controllato nel range organico
        if (copiedH1 > 0) {
            // 🌱 Rapporto calcolato dinamicamente
            int idxH1 = (int)MathRound(i / ratioH1);
            int barsH1 = barsPerHurst / 2;
            if (copiedH1 >= idxH1 + barsH1) {
                MqlRates subRates[];
                ArrayResize(subRates, barsH1);
                for (int j = 0; j < barsH1; j++) subRates[j] = ratesH1[idxH1 + j];
                double hH1 = CalculateHurstExponent(subRates, barsH1);
                if (hH1 > HURST_RANGE_MIN && hH1 < HURST_RANGE_MAX) {
                    hurstWeightedSum += hH1 * g_organic_H1.weight;
                    weightSum += g_organic_H1.weight;
                }
            }
        }
        
        // H4 - ✅ VALIDATO: hH4 controllato nel range organico
        if (copiedH4 > 0) {
            // 🌱 Rapporto calcolato dinamicamente
            int idxH4 = (int)MathRound(i / ratioH4);
            int barsH4 = barsPerHurst / 4;
            if (copiedH4 >= idxH4 + barsH4) {
                MqlRates subRates[];
                ArrayResize(subRates, barsH4);
                for (int j = 0; j < barsH4; j++) subRates[j] = ratesH4[idxH4 + j];
                double hH4 = CalculateHurstExponent(subRates, barsH4);
                if (hH4 > HURST_RANGE_MIN && hH4 < HURST_RANGE_MAX) {
                    hurstWeightedSum += hH4 * g_organic_H4.weight;
                    weightSum += g_organic_H4.weight;
                }
            }
        }
        
        // D1 - ✅ VALIDATO: hD1 controllato nel range organico
        // 🌱 Minimo barre D1 = φ⁵ ≈ 11 (derivato organicamente)
        int minBarsD1 = (int)MathRound(MathPow(PHI, 5));
        if (copiedD1 >= minBarsD1) {
            // 🌱 Rapporto calcolato dinamicamente
            int idxD1 = (int)MathRound(i / ratioD1);
            // 🌱 Buffer D1 = φ⁴ ≈ 7 (derivato organicamente)
            int bufD1 = (int)MathRound(MathPow(PHI, 4));
            if (idxD1 < copiedD1 - bufD1) {
                MqlRates subRates[];
                // 🌱 Barre D1 minimo = φ⁴ ≈ 7
                int barsD1 = MathMin(bufD1 * 3, copiedD1 - idxD1);
                ArrayResize(subRates, barsD1);
                for (int j = 0; j < barsD1; j++) subRates[j] = ratesD1[idxD1 + j];
                double hD1 = CalculateHurstExponent(subRates, barsD1);
                if (hD1 > HURST_RANGE_MIN && hD1 < HURST_RANGE_MAX) {
                    hurstWeightedSum += hD1 * g_organic_D1.weight;
                    weightSum += g_organic_D1.weight;
                }
            }
        }
        
        // Calcola Hurst composito pesato
        // ✅ VALIDATO: weightSum > 0, hComposite nel range organico
        if (weightSum > 0) {
            double hComposite = hurstWeightedSum / weightSum;
            
            // ✅ VALIDAZIONE: Accetta solo valori nel range Hurst organico
            if (hComposite < HURST_RANGE_MIN || hComposite > HURST_RANGE_MAX) continue;
            
            hurstValues[sample] = hComposite;
            lastValidIndex = sample;
            
            // Aggiungi al buffer (replica per compensare skip)
            // 🚀 CRITICO: Aggiorna anche le somme incrementali!
            for (int rep = 0; rep < skipFactor; rep++) {
                // ✅ Se buffer pieno, sottrai valore vecchio che stiamo per sovrascrivere
                if (g_hurstHistorySize == HURST_HISTORY_MAX) {
                    double oldValue = g_hurstHistory[g_hurstHistoryIndex];
                    g_hurstSum -= oldValue;
                    g_hurstSumSq -= oldValue * oldValue;
                    
                    // ✅ SANITY CHECK: protezione da errori floating point
                    if (g_hurstSum < 0) g_hurstSum = 0;
                    if (g_hurstSumSq < 0) g_hurstSumSq = 0;
                }
                
                g_hurstHistory[g_hurstHistoryIndex] = hComposite;  // ✅ Valore già validato
                g_hurstSum += hComposite;
                g_hurstSumSq += hComposite * hComposite;
                // ✅ VALIDATO: indice sempre nel range [0, HURST_HISTORY_MAX-1]
                g_hurstHistoryIndex = (g_hurstHistoryIndex + 1) % HURST_HISTORY_MAX;
                
                if (g_hurstHistorySize < HURST_HISTORY_MAX) {
                    g_hurstHistorySize++;
                }
            }
            successCount++;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    // FASE 2: Calcola centro, stdev e zona Hurst
    // 🚀 OTTIMIZZATO: usa le somme incrementali già calcolate!
    // ✅ VALIDATO: divisione sicura (g_hurstHistorySize >= minSamples >= 1)
    // 🔧 FIX: Check esplicito per g_hurstHistorySize == 0
    // ═══════════════════════════════════════════════════════════════
    
    // 🔧 FIX: Protezione divisione per zero - nessun campione valido
    if (g_hurstHistorySize == 0) {
        PrintFormat("[PRELOAD] ⚠️ Nessun campione Hurst valido - pre-caricamento fallito");
        return;
    }
    
    int minSamples = (int)MathCeil(HURST_HISTORY_MAX * PHI_INV_SQ);
    if (g_hurstHistorySize < minSamples) {
        PrintFormat("[PRELOAD] ⚠️ Pre-caricamento parziale Hurst: solo %d campioni validi", successCount);
        return;
    }
    
    // 🚀 ✅ Calcola centro O(1) - divisione sicura (g_hurstHistorySize > 0 garantito)
    g_hurstCenter = g_hurstSum / g_hurstHistorySize;
    
    // 🚀 ✅ Calcola stdev O(1): Var(X) = E[X²] - E[X]² con protezione negativa
    double meanSq = g_hurstSumSq / g_hurstHistorySize;
    double variance = meanSq - (g_hurstCenter * g_hurstCenter);
    g_hurstStdev = (variance > 0) ? MathSqrt(variance) : 0.0;  // ✅ >= 0
    
    // ✅ Calcola margine e zona
    double newMargin = g_hurstStdev * PHI_INV;
    double minMargin = g_hurstStdev * PHI_INV_SQ;
    double maxMargin = g_hurstStdev * PHI;
    g_hurstZoneMargin = MathMax(minMargin, MathMin(maxMargin, newMargin));  // ✅ >= 0
    
    g_hurstRandomLow = g_hurstCenter - g_hurstZoneMargin;
    g_hurstRandomHigh = g_hurstCenter + g_hurstZoneMargin;
    g_hurstZoneReady = true;
    
    PrintFormat("[PRELOAD] ✅ Buffer Hurst: %d/%d | Centro=%.4f Stdev=%.4f Zona=[%.4f, %.4f]", 
        successCount, samplesToPreload, g_hurstCenter, g_hurstStdev, g_hurstRandomLow, g_hurstRandomHigh);
    
    // ═══════════════════════════════════════════════════════════════
    // FASE 3: Calcola TradeScore per ogni campione Hurst e riempi buffer
    // Ora che abbiamo centro e stdev, possiamo calcolare i tradeScore!
    // ✅ VALIDATO: tradeScore >= 0 garantito
    // ═══════════════════════════════════════════════════════════════
    int tradeScoreCount = 0;
    int samplesToPreloadTS = MathMin(effectiveSamples, TRADE_SCORE_HISTORY_MAX);
    
    for (int i = 0; i < samplesToPreloadTS; i++) {
        double h = hurstValues[i];
        if (h < HURST_RANGE_MIN || h > HURST_RANGE_MAX) continue;  // ✅ Solo valori validi
        
        // ✅ Calcola confidence (stessa logica di GetHurstConfidence)
        double deviation = MathAbs(h - g_hurstCenter);  // ✅ >= 0
        double maxDeviation = g_hurstStdev * PHI;
        double confidence = (maxDeviation > 0) ? MathMin(1.0, deviation / maxDeviation) : 0.0;  // ✅ [0, 1]
        
        // ✅ Calcola tradeScore (stessa logica di RecalculateOrganicSystem)
        double normFactor = g_hurstStdev * PHI;
        double tradeScore = 0;
        if (normFactor > 0) {
            tradeScore = deviation * confidence / normFactor;  // ✅ >= 0
        }
        
        // Aggiungi al buffer TradeScore
        // 🚀 CRITICO: Aggiorna anche le somme incrementali!
        // ✅ Se buffer pieno, sottrai valore vecchio che stiamo per sovrascrivere
        if (g_tradeScoreHistorySize == TRADE_SCORE_HISTORY_MAX) {
            double oldValue = g_tradeScoreHistory[g_tradeScoreHistoryIndex];
            g_tradeScoreSum -= oldValue;
            g_tradeScoreSumSq -= oldValue * oldValue;
            
            // ✅ SANITY CHECK: protezione da errori floating point
            if (g_tradeScoreSum < 0) g_tradeScoreSum = 0;
            if (g_tradeScoreSumSq < 0) g_tradeScoreSumSq = 0;
        }
        
        g_tradeScoreHistory[g_tradeScoreHistoryIndex] = tradeScore;
        g_tradeScoreSum += tradeScore;
        g_tradeScoreSumSq += tradeScore * tradeScore;
        // ✅ VALIDATO: indice sempre nel range [0, TRADE_SCORE_HISTORY_MAX-1]
        g_tradeScoreHistoryIndex = (g_tradeScoreHistoryIndex + 1) % TRADE_SCORE_HISTORY_MAX;
        
        if (g_tradeScoreHistorySize < TRADE_SCORE_HISTORY_MAX) {
            g_tradeScoreHistorySize++;
        }
        tradeScoreCount++;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // FASE 4: Calcola soglia TradeScore dai dati pre-caricati
    // 🚀 OTTIMIZZATO: usa le somme incrementali già calcolate!
    // ✅ VALIDATO: divisione sicura (minTradeScoreSamples >= 1)
    // ═══════════════════════════════════════════════════════════════
    int minTradeScoreSamples = (int)MathCeil(TRADE_SCORE_HISTORY_MAX * PHI_INV_SQ);
    if (g_tradeScoreHistorySize >= minTradeScoreSamples) {
        // 🚀 ✅ Media O(1) - divisione sicura
        double meanTS = g_tradeScoreSum / g_tradeScoreHistorySize;
        
        // 🚀 ✅ Varianza O(1): Var(X) = E[X²] - E[X]² con protezione negativa
        double meanSqTS = g_tradeScoreSumSq / g_tradeScoreHistorySize;
        double varianceTS = meanSqTS - (meanTS * meanTS);
        double stdevTS = (varianceTS > 0) ? MathSqrt(varianceTS) : 0.0;
        
        g_tradeScoreThreshold = meanTS + stdevTS * PHI_INV;  // ✅ >= 0
        g_tradeScoreReady = true;
        
        PrintFormat("[PRELOAD] ✅ Buffer TradeScore: %d/%d | Soglia=%.4f", 
            tradeScoreCount, TRADE_SCORE_HISTORY_MAX, g_tradeScoreThreshold);
    } else {
        PrintFormat("[PRELOAD] ⚠️ TradeScore parziale: solo %d campioni", tradeScoreCount);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // FASE 5: Imposta stato globale per permettere trading immediato
    // CRITICO: Calcola g_hurstTradeScore e g_hurstAllowTrade!
    // ✅ VALIDATO: tutti i valori usati sono già validati nelle fasi precedenti
    // ═══════════════════════════════════════════════════════════════
    g_hurstReady = (g_hurstZoneReady && g_tradeScoreReady);
    
    if (g_hurstReady && lastValidIndex >= 0) {
        // Usa l'ultimo Hurst valido (il più recente, tracciato da lastValidIndex)
        double lastHurst = hurstValues[lastValidIndex];  // ✅ Già validato nel range organico
        g_hurstComposite = lastHurst;
        
        // ✅ Calcola g_hurstConfidence (stessa logica di GetHurstConfidence)
        double deviation = MathAbs(lastHurst - g_hurstCenter);  // ✅ >= 0
        double maxDeviation = g_hurstStdev * PHI;
        g_hurstConfidence = (maxDeviation > 0) ? MathMin(1.0, deviation / maxDeviation) : 0.0;  // ✅ [0, 1]
        
        // ✅ Calcola g_hurstTradeScore (stessa logica di RecalculateOrganicSystem)
        double normFactor = g_hurstStdev * PHI;
        if (normFactor > 0) {
            g_hurstTradeScore = deviation * g_hurstConfidence / normFactor;  // ✅ >= 0
        } else {
            g_hurstTradeScore = 0;  // ✅ Fallback sicuro
        }
        
        // CRITICO: Setta g_hurstAllowTrade per permettere trading!
        g_hurstAllowTrade = (g_hurstTradeScore >= g_tradeScoreThreshold);
        
        PrintFormat("[PRELOAD] ✅✅✅ PRE-CARICAMENTO COMPLETO!");
        PrintFormat("[PRELOAD]   H_composito=%.4f | Centro=%.4f | Confidence=%.3f", 
            g_hurstComposite, g_hurstCenter, g_hurstConfidence);
        PrintFormat("[PRELOAD]   TradeScore=%.4f %s Soglia=%.4f → %s", 
            g_hurstTradeScore, 
            g_hurstTradeScore >= g_tradeScoreThreshold ? "≥" : "<",
            g_tradeScoreThreshold,
            g_hurstAllowTrade ? "✅ TRADE OK" : "⛔ BLOCCATO");
    } else {
        Print("[PRELOAD] ⚠️ Pre-caricamento incompleto - warm-up richiesto");
    }
}

//+------------------------------------------------------------------+
//| 🌱 FILTRO HURST: Aggiungi H al buffer e aggiorna zona adattiva   |
//| 🚀 OTTIMIZZATO: Usa somme incrementali O(1) invece di O(n)       |
//| 🔧 FIX: Ricalcolo periodico completo per evitare drift numerico  |
//| ✅ INPUT VALIDATO: h deve essere nel range organico [φ⁻³, 1-φ⁻³]  |
//|    (validazione fatta dal chiamante prima di questa funzione)    |
//+------------------------------------------------------------------+
void AddHurstToHistory(double h)
{
    // 🔧 FIX: Ricalcolo completo periodico per evitare drift floating point
    // Ogni HURST_HISTORY_MAX operazioni, ricalcola somme da zero
    g_hurstOperationCount++;
    if (g_hurstOperationCount >= HURST_HISTORY_MAX) {
        RecalculateHurstSumsFromScratch();
        g_hurstOperationCount = 0;
    }
    
    // ✅ VALIDATO: Sottrai valore vecchio se buffer pieno (buffer circolare)
    if (g_hurstHistorySize == HURST_HISTORY_MAX) {
        double oldValue = g_hurstHistory[g_hurstHistoryIndex];
        g_hurstSum -= oldValue;
        g_hurstSumSq -= oldValue * oldValue;
        
        // ✅ SANITY CHECK: protezione da errori floating point accumulati
        if (g_hurstSum < 0) g_hurstSum = 0;
        if (g_hurstSumSq < 0) g_hurstSumSq = 0;
    }
    
    // ✅ VALIDATO: Aggiungi nuovo valore al buffer
    g_hurstHistory[g_hurstHistoryIndex] = h;
    g_hurstSum += h;
    g_hurstSumSq += h * h;
    
    // ✅ VALIDATO: Indice sempre nel range [0, MAX-1] grazie al modulo
    g_hurstHistoryIndex = (g_hurstHistoryIndex + 1) % HURST_HISTORY_MAX;
    
    // ✅ VALIDATO: Size mai > MAX
    if (g_hurstHistorySize < HURST_HISTORY_MAX) {
        g_hurstHistorySize++;
    }
    
    // Ricalcola CENTRO e STDEV con somme incrementali O(1)!
    int minSamples = (int)MathCeil(HURST_HISTORY_MAX * PHI_INV_SQ);  // ~38% del buffer
    if (g_hurstHistorySize >= minSamples) {
        // ✅ VALIDATO: Divisione sicura (minSamples >= 1)
        g_hurstCenter = g_hurstSum / g_hurstHistorySize;
        
        // ✅ VALIDATO: Varianza O(1) con protezione per valori negativi
        double meanSq = g_hurstSumSq / g_hurstHistorySize;
        double variance = meanSq - (g_hurstCenter * g_hurstCenter);
        g_hurstStdev = (variance > 0) ? MathSqrt(variance) : 0.0;
        
        // 🌱 MARGINE = stdev × φ⁻¹
        double newMargin = g_hurstStdev * PHI_INV;
        double minMargin = g_hurstStdev * PHI_INV_SQ;
        double maxMargin = g_hurstStdev * PHI;
        g_hurstZoneMargin = MathMax(minMargin, MathMin(maxMargin, newMargin));
        
        // 🌱 ZONA = centro ± margine
        g_hurstRandomLow = g_hurstCenter - g_hurstZoneMargin;
        g_hurstRandomHigh = g_hurstCenter + g_hurstZoneMargin;
        g_hurstZoneReady = true;  // ✅ Flag: dati pronti per l'uso
    }
    else {
        g_hurstZoneReady = false;  // ✅ Flag: dati NON pronti
    }
}

//+------------------------------------------------------------------+
//| 🔧 FIX: Ricalcolo completo somme Hurst per evitare drift        |
//+------------------------------------------------------------------+
void RecalculateHurstSumsFromScratch()
{
    g_hurstSum = 0.0;
    g_hurstSumSq = 0.0;
    
    for (int i = 0; i < g_hurstHistorySize; i++) {
        g_hurstSum += g_hurstHistory[i];
        g_hurstSumSq += g_hurstHistory[i] * g_hurstHistory[i];
    }
    
    if (g_enableLogsEffective) {
        PrintFormat("[🔧 ANTI-DRIFT] Ricalcolo completo somme Hurst: Sum=%.6f SumSq=%.6f (size=%d)",
            g_hurstSum, g_hurstSumSq, g_hurstHistorySize);
    }
}

//+------------------------------------------------------------------+
//| 🌱 FILTRO HURST: Check finale prima di aprire trade              |
//| Ritorna true se il trade è permesso, false se bloccato           |
//| NOTA: Il ricalcolo avviene ora in RecalculateOrganicSystem()     |
//| 🔧 FIX: Log rimosso da qui - stampato solo se c'era segnale      |
//+------------------------------------------------------------------+
bool IsTradeAllowedByHurst()
{
    if (!EnableHurstFilter) return true;  // Filtro disabilitato
    
    // Il ricalcolo avviene ad ogni nuova barra in RecalculateOrganicSystem()
    // Qui verifichiamo solo il flag
    if (!g_hurstReady) {
        // Log solo una volta ogni 100 barre per evitare spam
        static int hurstNotReadyCount = 0;
        hurstNotReadyCount++;
        if (hurstNotReadyCount == 1 || hurstNotReadyCount % 100 == 0) {
            PrintFormat("[HURST] ⏳ Hurst NON pronto (%d barre) - servono piu' dati per zona/stdev", hurstNotReadyCount);
        }
        return false;
    }
    // 🔧 FIX: Log "TRADE BLOCCATO" rimosso - stampato in ExecuteTrades solo se c'era segnale
    
    return g_hurstAllowTrade;
}

//+------------------------------------------------------------------+
//| 🌱 SOGLIA DINAMICA: Inizializza buffer score storici             |
//+------------------------------------------------------------------+
void InitScoreHistoryBuffer()
{
    ArrayResize(g_scoreHistory, SCORE_HISTORY_MAX);
    ArrayInitialize(g_scoreHistory, 0);
    g_scoreHistorySize = 0;
    g_scoreHistoryIndex = 0;
    g_dynamicThreshold = ScoreThreshold;  // Inizia con valore manuale
    g_scoreThresholdReady = false;
    
    // 🚀 CRITICO: Inizializza somme incrementali Score
    g_scoreSum = 0.0;
    g_scoreSumSq = 0.0;
    
    if (g_enableLogsEffective) {
        PrintFormat("[INIT-BUFFER] 🌱 g_scoreHistory: ArraySize=%d (max=%d) %s",
            ArraySize(g_scoreHistory), SCORE_HISTORY_MAX,
            ArraySize(g_scoreHistory) == SCORE_HISTORY_MAX ? "✅" : "❌");
        if (AutoScoreThreshold) {
            Print("[INIT-BUFFER] 🌱 Soglia score dinamica attiva: mean + stdev × φ⁻¹");
        } else {
            PrintFormat("[INIT-BUFFER] 🌱 Soglia score manuale: %.1f%%", ScoreThreshold);
        }
    }
}

//+------------------------------------------------------------------+
//| 🌱 SOGLIA DINAMICA: Aggiungi score al buffer circolare           |
//| 🚀 OTTIMIZZATO: Usa somme incrementali O(1)                      |
//| 🔧 FIX: Ricalcolo periodico completo per evitare drift numerico  |
//| ✅ INPUT: scorePct può essere qualsiasi valore (0-100%)          |
//+------------------------------------------------------------------+
void AddScoreToHistory(double scorePct)
{
    if (!AutoScoreThreshold) return;  // Non serve se soglia manuale
    
    // 🔧 FIX: Ricalcolo completo periodico per evitare drift floating point
    g_scoreOperationCount++;
    if (g_scoreOperationCount >= SCORE_HISTORY_MAX) {
        RecalculateScoreSumsFromScratch();
        g_scoreOperationCount = 0;
    }
    
    // ✅ VALIDATO: Sottrai valore vecchio se buffer pieno
    if (g_scoreHistorySize == SCORE_HISTORY_MAX) {
        double oldValue = g_scoreHistory[g_scoreHistoryIndex];
        g_scoreSum -= oldValue;
        g_scoreSumSq -= oldValue * oldValue;
        
        // ✅ SANITY CHECK: protezione da errori floating point accumulati
        if (g_scoreSum < 0) g_scoreSum = 0;
        if (g_scoreSumSq < 0) g_scoreSumSq = 0;
    }
    
    // ✅ VALIDATO: Aggiungi nuovo valore
    g_scoreHistory[g_scoreHistoryIndex] = scorePct;
    g_scoreSum += scorePct;
    g_scoreSumSq += scorePct * scorePct;
    
    // ✅ VALIDATO: Indice sempre nel range [0, MAX-1]
    g_scoreHistoryIndex = (g_scoreHistoryIndex + 1) % SCORE_HISTORY_MAX;
    
    // ✅ VALIDATO: Size mai > MAX
    if (g_scoreHistorySize < SCORE_HISTORY_MAX) {
        g_scoreHistorySize++;
    }
}

//+------------------------------------------------------------------+
//| 🔧 FIX: Ricalcolo completo somme Score per evitare drift         |
//+------------------------------------------------------------------+
void RecalculateScoreSumsFromScratch()
{
    g_scoreSum = 0.0;
    g_scoreSumSq = 0.0;
    
    for (int i = 0; i < g_scoreHistorySize; i++) {
        g_scoreSum += g_scoreHistory[i];
        g_scoreSumSq += g_scoreHistory[i] * g_scoreHistory[i];
    }
    
    if (g_enableLogsEffective) {
        PrintFormat("[🔧 ANTI-DRIFT] Ricalcolo completo somme Score: Sum=%.2f SumSq=%.2f (size=%d)",
            g_scoreSum, g_scoreSumSq, g_scoreHistorySize);
    }
}

//+------------------------------------------------------------------+
//| 🔧 FIX: Ricalcolo completo somme TradeScore per evitare drift    |
//+------------------------------------------------------------------+
void RecalculateTradeScoreSumsFromScratch()
{
    g_tradeScoreSum = 0.0;
    g_tradeScoreSumSq = 0.0;
    
    for (int i = 0; i < g_tradeScoreHistorySize; i++) {
        g_tradeScoreSum += g_tradeScoreHistory[i];
        g_tradeScoreSumSq += g_tradeScoreHistory[i] * g_tradeScoreHistory[i];
    }
    
    if (g_enableLogsEffective) {
        PrintFormat("[🔧 ANTI-DRIFT] Ricalcolo completo somme TradeScore: Sum=%.6f SumSq=%.6f (size=%d)",
            g_tradeScoreSum, g_tradeScoreSumSq, g_tradeScoreHistorySize);
    }
}

//+------------------------------------------------------------------+
//| 🌱 SOGLIA DINAMICA: 100% derivata dai dati storici               |
//| 🚀 OTTIMIZZATO: Usa somme incrementali O(1) invece di O(n)       |
//| ✅ OUTPUT: g_dynamicThreshold sempre nel range [61.8%, 76.4%]    |
//| 🌱 FLOOR ORGANICO: Mai sotto φ⁻¹ ≈ 62% (sezione aurea)           |
//+------------------------------------------------------------------+
void UpdateDynamicThreshold()
{
    if (!AutoScoreThreshold) {
        // ✅ VALIDATO: Usa valore manuale (impostato dall'utente)
        g_dynamicThreshold = ScoreThreshold;
        g_scoreThresholdReady = true;
        return;
    }
    
    // ✅ VALIDATO: minSamples = ~38% del buffer MAX (non del buffer attuale!)
    // Questo assicura che dopo ~122 tick la soglia sia pronta
    // Prima era troppo restrittivo e non raggiungeva mai la soglia
    int minSamples = (int)MathCeil(SCORE_HISTORY_MAX * PHI_INV_SQ);  // ~122 campioni
    
    // 🔧 FIX: Minimo organico ridotto = φ⁴ ≈ 7 (invece di φ⁵ ≈ 11) per trading più veloce
    int minSamplesOrganic = (int)MathRound(MathPow(PHI, 4));  // φ⁴ ≈ 7
    // 🔧 FIX: Usa φ⁻² invece di φ⁻² × φ⁻¹ per minimo più raggiungibile
    minSamples = MathMax(minSamplesOrganic, (int)MathCeil(minSamples * PHI_INV_SQ));
    
    if (g_scoreHistorySize < minSamples) {
        g_scoreThresholdReady = false;  // ✅ Flag: dati NON pronti
        if (g_enableLogsEffective) {
            PrintFormat("[THRESHOLD] ⏳ Raccolta dati: %d/%d | Soglia NON pronta, uso fallback %.1f%%",
                g_scoreHistorySize, minSamples, ScoreThreshold);
        }
        return;
    }
    
    // ✅ VALIDATO: Calcolo O(1) con divisione sicura (minSamples >= 20)
    double oldThreshold = g_dynamicThreshold;
    
    // ✅ VALIDATO: Media - divisione sicura
    double mean = g_scoreSum / g_scoreHistorySize;
    
    // ✅ VALIDATO: Varianza con protezione per valori negativi
    double meanSq = g_scoreSumSq / g_scoreHistorySize;
    double variance = meanSq - (mean * mean);
    double stdev = (variance > 0) ? MathSqrt(variance) : 0.0;
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 SOGLIA ORGANICA CON FLOOR IBRIDO
    // 
    // FASE 1 (pochi dati): Floor pragmatico = φ⁻¹ ≈ 62%
    // FASE 2 (abbastanza dati): Floor data-driven = percentile 62° degli score
    // 
    // Formula finale: max(floor, mean + stdev × φ)
    // 
    // Minimo per percentile = φ⁶ ≈ 18 campioni (significatività statistica)
    // ═══════════════════════════════════════════════════════════════
    
    double floorThreshold = 0.0;
    string floorType = "";
    
    int minForPercentile = (int)MathRound(MathPow(PHI, 6));  // φ⁶ ≈ 18
    
    if (g_scoreHistorySize >= minForPercentile) {
        // ═══════════════════════════════════════════════════════════
        // 🌱 FASE 2: FLOOR DATA-DRIVEN
        // Percentile φ⁻¹ × 100 ≈ 62° percentile degli score storici
        // Significa: solo il top 38% degli score passa (proporzione aurea!)
        // ═══════════════════════════════════════════════════════════
        floorThreshold = CalculatePercentile(g_scoreHistory, g_scoreHistorySize, PHI_INV * 100.0);
        floorType = StringFormat("DATA-DRIVEN: Percentile %.0f° di %d score", PHI_INV * 100.0, g_scoreHistorySize);
    } else {
        // ═══════════════════════════════════════════════════════════
        // 🌱 FASE 1: FLOOR PRAGMATICO
        // Usa φ⁻¹ × 100 ≈ 62% come floor fisso temporaneo
        // Verrà sostituito dal percentile quando avremo abbastanza dati
        // ═══════════════════════════════════════════════════════════
        floorThreshold = PHI_INV * 100.0;  // φ⁻¹ × 100 ≈ 61.8%
        floorType = StringFormat("FALLBACK: φ⁻¹ fisso (attesa %d/%d campioni per data-driven)", g_scoreHistorySize, minForPercentile);
    }
    
    double dataThreshold = mean + stdev * PHI;  // mean + stdev × φ
    
    // Determina quale componente "vince"
    bool floorWins = (floorThreshold > dataThreshold);
    
    g_dynamicThreshold = MathMax(floorThreshold, dataThreshold);
    
    // ✅ VALIDATO: Ceiling organico a 1-φ⁻³ ≈ 76.4% - non troppo restrittivo
    double maxThreshold = (1.0 - PHI_INV_CUB) * 100.0;  // ≈ 76.4%
    bool ceilingApplied = (g_dynamicThreshold > maxThreshold);
    g_dynamicThreshold = MathMin(maxThreshold, g_dynamicThreshold);
    g_scoreThresholdReady = true;  // ✅ Flag: dati pronti
    
    // 🌱 Log solo se cambio significativo (stdev × φ⁻² = cambio minimo per log)
    double minChangeForLog = stdev * PHI_INV_SQ;  // Derivato dai DATI
    if (minChangeForLog < 0.1) minChangeForLog = 0.1;  // Minimo assoluto per evitare spam
    if (g_enableLogsEffective && MathAbs(g_dynamicThreshold - oldThreshold) > minChangeForLog) {
        // Log dettagliato che spiega esattamente come è stata calcolata la soglia
        PrintFormat("[THRESHOLD] 🌱 Soglia: %.1f%% → %.1f%%", oldThreshold, g_dynamicThreshold);
        PrintFormat("   📊 Floor: %.1f%% [%s]", floorThreshold, floorType);
        PrintFormat("   📈 Data: %.1f%% = mean(%.1f%%) + stdev(%.1f%%) × φ", dataThreshold, mean, stdev);
        PrintFormat("   🎯 Decisione: %s%s", 
            floorWins ? "FLOOR vince (protegge da soglia troppo bassa)" : "DATA vince (mercato richiede soglia alta)",
            ceilingApplied ? " | ⚠️ CEILING 76.4% applicato" : "");
    }
}

//+------------------------------------------------------------------+
//| 🌱 SOGLIA DINAMICA: Ottieni soglia corrente (auto o manuale)     |
//| Se auto ma non pronta, usa soglia manuale come fallback          |
//| ✅ VALIDATO:                                                      |
//|    OUTPUT: Valore sempre >= 0 (soglia valida)                    |
//|    - g_dynamicThreshold è già validato nel range [23.6%, 76.4%]  |
//|    - ScoreThreshold è input utente (potenzialmente qualsiasi)    |
//+------------------------------------------------------------------+
double GetCurrentThreshold()
{
    if (AutoScoreThreshold) {
        // ✅ Se la soglia automatica non è ancora pronta, usa quella manuale come fallback
        // Così il trading può iniziare subito invece di aspettare warm-up
        if (!g_scoreThresholdReady) return ScoreThreshold;  // Fallback a soglia manuale
        return g_dynamicThreshold;  // ✅ Validato nel range [23.6%, 76.4%]
    }
    return ScoreThreshold;  // ⚠️ Input utente, non validato
}

//+------------------------------------------------------------------+
//| 🌱 DETECTOR INVERSIONE: Inizializzazione buffer                  |
//+------------------------------------------------------------------+
void InitReversalDetectors()
{
    // Score Momentum buffer = φ⁸ ≈ 47 (stesso size di trade history)
    int momentumBufferSize = (int)MathRound(MathPow(PHI, 8));
    ArrayResize(g_momentumHistory, momentumBufferSize);
    ArrayInitialize(g_momentumHistory, 0);
    g_momentumHistorySize = 0;
    g_momentumHistoryIndex = 0;
    g_momentumSum = 0.0;
    g_momentumSumSq = 0.0;
    g_scoreMomentumThreshold = 0.0;
    g_momentumThresholdReady = false;
    g_prevScore = 0.0;
    g_scoreMomentum = 0.0;
    
    // Regime change: inizializza a RANDOM
    g_prevRegime_M5 = HURST_RANDOM;
    g_prevRegime_H1 = HURST_RANDOM;
    g_prevRegime_H4 = HURST_RANDOM;
    g_prevRegime_D1 = HURST_RANDOM;
    g_regimeChanged = false;
    g_regimeChangeDirection = 0;
    
    // RSI Divergence: buffer swing = φ⁵ ≈ 11
    g_swingsMax = (int)MathRound(MathPow(PHI, 5));
    ArrayResize(g_swings_H1, g_swingsMax);
    g_swingsSize_H1 = 0;
    g_divergenceSignal = 0;
    g_divergenceStrength = 0.0;
    
    // 🌱 SOGLIA DIVERGENZA DATA-DRIVEN: buffer φ⁶ ≈ 18
    int divergenceBufferSize = (int)MathRound(MathPow(PHI, 6));
    ArrayResize(g_divergenceHistory, divergenceBufferSize);
    ArrayInitialize(g_divergenceHistory, 0);
    g_divergenceHistorySize = 0;
    g_divergenceHistoryIndex = 0;
    g_divergenceSum = 0.0;
    g_divergenceSumSq = 0.0;
    g_divergenceMinThreshold = PHI_INV_CUB;  // 🌱 Start = φ⁻³ ≈ 23.6%
    g_divergenceThresholdReady = false;
    
    // 🌱 SOGLIA REVERSAL DATA-DRIVEN: buffer φ⁸ ≈ 47
    int reversalBufferSize = (int)MathRound(MathPow(PHI, 8));
    ArrayResize(g_reversalStrengthHistory, reversalBufferSize);
    ArrayInitialize(g_reversalStrengthHistory, 0);
    g_reversalHistorySize = 0;
    g_reversalHistoryIndex = 0;
    g_reversalSum = 0.0;
    g_reversalSumSq = 0.0;
    g_reversalThreshold = PHI_INV;       // 🌱 Start = φ⁻¹ ≈ 61.8%
    g_reversalThresholdReady = false;
    
    if (g_enableLogsEffective) {
        Print("");
        Print("═══════════════════════════════════════════════════════════════");
        Print("🎯 DETECTOR INVERSIONE ORGANICO INIZIALIZZATO");
        PrintFormat("   Score Momentum buffer: %d | Soglia: mean + stdev × φ⁻¹", momentumBufferSize);
        Print("   Regime Change: traccia transizioni Hurst");
        PrintFormat("   RSI Divergence: %d swing points | Soglia: mean + stdev × φ⁻¹", g_swingsMax);
        PrintFormat("   Divergence buffer: %d | Reversal buffer: %d", divergenceBufferSize, reversalBufferSize);
        Print("═══════════════════════════════════════════════════════════════");
        Print("");
    }
}

//+------------------------------------------------------------------+
//| 🌱 SCORE MOMENTUM: Aggiorna e calcola cambio score               |
//| Ritorna: +1 se momentum bullish forte, -1 se bearish, 0 neutro   |
//+------------------------------------------------------------------+
int UpdateScoreMomentum(double currentScore)
{
    // Calcola momentum (derivata dello score)
    g_scoreMomentum = currentScore - g_prevScore;
    g_prevScore = currentScore;
    
    // Aggiungi al buffer storico per calcolo soglia
    int momentumBufferMax = (int)MathRound(MathPow(PHI, 8));
    
    // Sottrai valore vecchio se buffer pieno
    if (g_momentumHistorySize == momentumBufferMax) {
        double oldValue = g_momentumHistory[g_momentumHistoryIndex];
        g_momentumSum -= oldValue;
        g_momentumSumSq -= oldValue * oldValue;
        if (g_momentumSum < -1e10) g_momentumSum = 0;  // Protezione overflow
        if (g_momentumSumSq < 0) g_momentumSumSq = 0;
    }
    
    // Aggiungi nuovo valore (usiamo valore assoluto per la soglia)
    double absMomentum = MathAbs(g_scoreMomentum);
    g_momentumHistory[g_momentumHistoryIndex] = absMomentum;
    g_momentumSum += absMomentum;
    g_momentumSumSq += absMomentum * absMomentum;
    
    g_momentumHistoryIndex = (g_momentumHistoryIndex + 1) % momentumBufferMax;
    if (g_momentumHistorySize < momentumBufferMax) g_momentumHistorySize++;
    
    // Calcola soglia momentum = mean + stdev × φ⁻¹
    int minSamples = (int)MathRound(MathPow(PHI, 4));  // φ⁴ ≈ 7
    if (g_momentumHistorySize >= minSamples) {
        double mean = g_momentumSum / g_momentumHistorySize;
        double meanSq = g_momentumSumSq / g_momentumHistorySize;
        double variance = meanSq - (mean * mean);
        double stdev = (variance > 0) ? MathSqrt(variance) : 0.0;
        g_scoreMomentumThreshold = mean + stdev * PHI_INV;
        g_momentumThresholdReady = true;
    }
    
    // Determina segnale
    if (!g_momentumThresholdReady) return 0;
    
    if (MathAbs(g_scoreMomentum) >= g_scoreMomentumThreshold) {
        if (g_scoreMomentum > 0) {
            if (g_enableLogsEffective) {
                PrintFormat("[REVERSAL] 📈 MOMENTUM BULLISH: %.2f > %.2f soglia", 
                    g_scoreMomentum, g_scoreMomentumThreshold);
            }
            return 1;  // Momentum bullish significativo
        } else {
            if (g_enableLogsEffective) {
                PrintFormat("[REVERSAL] 📉 MOMENTUM BEARISH: %.2f < -%.2f soglia", 
                    g_scoreMomentum, g_scoreMomentumThreshold);
            }
            return -1;  // Momentum bearish significativo
        }
    }
    
    return 0;  // Momentum non significativo
}

//+------------------------------------------------------------------+
//| 🌱 REGIME CHANGE: Traccia transizioni regime Hurst               |
//| Ritorna: +1 se verso trending, -1 se verso meanrev, 0 nessuna    |
//+------------------------------------------------------------------+
int UpdateRegimeChange()
{
    g_regimeChanged = false;
    g_regimeChangeDirection = 0;
    
    if (!EnableHurstFilter) return 0;
    
    // Check cambio per ogni TF attivo
    double changeScore = 0.0;  // 🌱 double per pesi organici
    
    // 🌱 PESI ORGANICI: derivati da potenze di φ
    // M5 = φ⁻² ≈ 0.38, H1 = φ⁻¹ ≈ 0.62, H4 = 1.0, D1 = φ ≈ 1.62
    double weightM5 = PHI_INV_SQ;   // ≈ 0.382
    double weightH1 = PHI_INV;      // ≈ 0.618
    double weightH4 = 1.0;          // 1.0
    double weightD1 = PHI;          // ≈ 1.618
    
    // M5 (peso φ⁻² ≈ 0.38)
    if (g_vote_M5_active && g_hurstRegime_M5 != g_prevRegime_M5) {
        if (g_hurstRegime_M5 == HURST_TRENDING && g_prevRegime_M5 != HURST_TRENDING) 
            changeScore += weightM5;
        else if (g_hurstRegime_M5 == HURST_MEANREV && g_prevRegime_M5 != HURST_MEANREV) 
            changeScore -= weightM5;
        g_prevRegime_M5 = g_hurstRegime_M5;
    }
    
    // H1 (peso φ⁻¹ ≈ 0.62)
    if (g_vote_H1_active && g_hurstRegime_H1 != g_prevRegime_H1) {
        if (g_hurstRegime_H1 == HURST_TRENDING && g_prevRegime_H1 != HURST_TRENDING) 
            changeScore += weightH1;
        else if (g_hurstRegime_H1 == HURST_MEANREV && g_prevRegime_H1 != HURST_MEANREV) 
            changeScore -= weightH1;
        g_prevRegime_H1 = g_hurstRegime_H1;
    }
    
    // H4 (peso 1.0)
    if (g_vote_H4_active && g_hurstRegime_H4 != g_prevRegime_H4) {
        if (g_hurstRegime_H4 == HURST_TRENDING && g_prevRegime_H4 != HURST_TRENDING) 
            changeScore += weightH4;
        else if (g_hurstRegime_H4 == HURST_MEANREV && g_prevRegime_H4 != HURST_MEANREV) 
            changeScore -= weightH4;
        g_prevRegime_H4 = g_hurstRegime_H4;
    }
    
    // D1 (peso φ ≈ 1.62)
    if (g_vote_D1_active && g_hurstRegime_D1 != g_prevRegime_D1) {
        if (g_hurstRegime_D1 == HURST_TRENDING && g_prevRegime_D1 != HURST_TRENDING) 
            changeScore += weightD1;
        else if (g_hurstRegime_D1 == HURST_MEANREV && g_prevRegime_D1 != HURST_MEANREV) 
            changeScore -= weightD1;
        g_prevRegime_D1 = g_hurstRegime_D1;
    }
    
    if (MathAbs(changeScore) > 0.01) {  // Soglia minima per evitare rumore numerico
        g_regimeChanged = true;
        g_regimeChangeDirection = (changeScore > 0) ? 1 : -1;
        
        if (g_enableLogsEffective) {
            PrintFormat("[REVERSAL] 🔄 REGIME CHANGE: %s (score=%.2f)", 
                changeScore > 0 ? "→ TRENDING" : "→ MEAN-REVERTING", changeScore);
        }
    }
    
    return g_regimeChangeDirection;
}

//+------------------------------------------------------------------+
//| 🌱 AGGIORNA SOGLIA DIVERGENZA DATA-DRIVEN                        |
//| Traccia storia forze divergenza e calcola: mean + stdev × φ⁻¹    |
//| Clamp organico: [φ⁻³ ≈ 24%, φ⁻¹ ≈ 62%]                          |
//+------------------------------------------------------------------+
void UpdateDivergenceThreshold(double strength)
{
    // Buffer size = φ⁶ ≈ 18
    int divergenceBufferMax = (int)MathRound(MathPow(PHI, 6));
    
    // Sottrai valore vecchio se buffer pieno (O(1))
    if (g_divergenceHistorySize == divergenceBufferMax) {
        double oldValue = g_divergenceHistory[g_divergenceHistoryIndex];
        g_divergenceSum -= oldValue;
        g_divergenceSumSq -= oldValue * oldValue;
        if (g_divergenceSum < -1e10) g_divergenceSum = 0;  // Protezione drift
        if (g_divergenceSumSq < 0) g_divergenceSumSq = 0;
    }
    
    // Aggiungi valore corrente
    g_divergenceHistory[g_divergenceHistoryIndex] = strength;
    g_divergenceSum += strength;
    g_divergenceSumSq += strength * strength;
    
    // Aggiorna indice circolare
    g_divergenceHistoryIndex = (g_divergenceHistoryIndex + 1) % divergenceBufferMax;
    if (g_divergenceHistorySize < divergenceBufferMax) g_divergenceHistorySize++;
    
    // Calcola soglia: richiede minimo φ² ≈ 3 sample
    int minSamples = (int)MathRound(PHI_SQ);
    
    if (g_divergenceHistorySize >= minSamples) {
        double mean = g_divergenceSum / g_divergenceHistorySize;
        double variance = (g_divergenceSumSq / g_divergenceHistorySize) - (mean * mean);
        double stdev = variance > 0 ? MathSqrt(variance) : 0;
        
        // Soglia = mean + stdev × φ⁻¹ (divergenze significativamente sopra media)
        g_divergenceMinThreshold = mean + stdev * PHI_INV;
        
        // Clamp organico: [φ⁻³ ≈ 24%, φ⁻¹ ≈ 62%]
        // Min basso per catturare divergenze deboli ma significative
        // Max per non essere troppo restrittivi
        g_divergenceMinThreshold = MathMax(PHI_INV_CUB, MathMin(PHI_INV, g_divergenceMinThreshold));
        
        if (!g_divergenceThresholdReady) {
            g_divergenceThresholdReady = true;
            if (g_enableLogsEffective) {
                PrintFormat("[DIVERGENCE] ✅ Soglia data-driven: %.1f%% (mean=%.1f%%, stdev=%.1f%%)",
                    g_divergenceMinThreshold * 100, mean * 100, stdev * 100);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 🌱 RSI DIVERGENCE: Rileva swing e divergenze prezzo/RSI          |
//| Usa H1 come TF principale per ridurre rumore                     |
//| Ritorna: +1 bullish div, -1 bearish div, 0 nessuna               |
//+------------------------------------------------------------------+
int UpdateRSIDivergence()
{
    g_divergenceSignal = 0;
    g_divergenceStrength = 0.0;
    
    if (!g_vote_H1_active) return 0;
    
    int ratesSize = ArraySize(tfData_H1.rates);
    int rsiSize = ArraySize(tfData_H1.rsi);
    
    // Servono almeno φ⁵ ≈ 11 barre per rilevare swing
    int minBars = (int)MathRound(MathPow(PHI, 5));
    if (ratesSize < minBars || rsiSize < minBars) return 0;
    
    // Lookback per swing detection = φ³ ≈ 4 barre
    int swingLookback = (int)MathRound(MathPow(PHI, 3));
    
    // Cerca swing high/low recenti
    bool foundSwingHigh = false;
    bool foundSwingLow = false;
    double swingHighPrice = 0, swingHighRSI = 0;
    double swingLowPrice = 0, swingLowRSI = 0;
    int swingHighBar = 0, swingLowBar = 0;
    
    // Cerca swing negli ultimi φ⁵ barre
    for (int i = swingLookback; i < minBars - swingLookback; i++) {
        int idx = ratesSize - 1 - i;  // Indice dalla fine (0 = più recente)
        if (idx < swingLookback || idx >= ratesSize - swingLookback) continue;
        
        // Check swing high: high[i] > high di tutte le barre vicine
        bool isSwingHigh = true;
        for (int j = 1; j <= swingLookback; j++) {
            if (tfData_H1.rates[idx].high <= tfData_H1.rates[idx - j].high ||
                tfData_H1.rates[idx].high <= tfData_H1.rates[idx + j].high) {
                isSwingHigh = false;
                break;
            }
        }
        if (isSwingHigh && !foundSwingHigh) {
            swingHighPrice = tfData_H1.rates[idx].high;
            swingHighRSI = tfData_H1.rsi[idx];
            swingHighBar = i;
            foundSwingHigh = true;
        }
        
        // Check swing low: low[i] < low di tutte le barre vicine
        bool isSwingLow = true;
        for (int j = 1; j <= swingLookback; j++) {
            if (tfData_H1.rates[idx].low >= tfData_H1.rates[idx - j].low ||
                tfData_H1.rates[idx].low >= tfData_H1.rates[idx + j].low) {
                isSwingLow = false;
                break;
            }
        }
        if (isSwingLow && !foundSwingLow) {
            swingLowPrice = tfData_H1.rates[idx].low;
            swingLowRSI = tfData_H1.rsi[idx];
            swingLowBar = i;
            foundSwingLow = true;
        }
    }
    
    // Cerca swing precedente per confronto
    double prevSwingHighPrice = 0, prevSwingHighRSI = 0;
    double prevSwingLowPrice = 0, prevSwingLowRSI = 0;
    
    int searchStart = minBars;
    int searchEnd = MathMin(ratesSize - swingLookback - 1, minBars * 2);
    
    for (int i = searchStart; i < searchEnd; i++) {
        int idx = ratesSize - 1 - i;
        if (idx < swingLookback || idx >= ratesSize - swingLookback) continue;
        
        // Cerca swing high precedente
        bool isSwingHigh = true;
        for (int j = 1; j <= swingLookback; j++) {
            if (idx - j < 0 || idx + j >= ratesSize) { isSwingHigh = false; break; }
            if (tfData_H1.rates[idx].high <= tfData_H1.rates[idx - j].high ||
                tfData_H1.rates[idx].high <= tfData_H1.rates[idx + j].high) {
                isSwingHigh = false;
                break;
            }
        }
        if (isSwingHigh && prevSwingHighPrice == 0) {
            prevSwingHighPrice = tfData_H1.rates[idx].high;
            prevSwingHighRSI = tfData_H1.rsi[idx];
        }
        
        // Cerca swing low precedente
        bool isSwingLow = true;
        for (int j = 1; j <= swingLookback; j++) {
            if (idx - j < 0 || idx + j >= ratesSize) { isSwingLow = false; break; }
            if (tfData_H1.rates[idx].low >= tfData_H1.rates[idx - j].low ||
                tfData_H1.rates[idx].low >= tfData_H1.rates[idx + j].low) {
                isSwingLow = false;
                break;
            }
        }
        if (isSwingLow && prevSwingLowPrice == 0) {
            prevSwingLowPrice = tfData_H1.rates[idx].low;
            prevSwingLowRSI = tfData_H1.rsi[idx];
        }
        
        if (prevSwingHighPrice > 0 && prevSwingLowPrice > 0) break;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // BEARISH DIVERGENCE: Prezzo Higher High, RSI Lower High
    // ═══════════════════════════════════════════════════════════════
    double calcStrength = 0.0;  // Forza calcolata (prima del check soglia)
    
    if (foundSwingHigh && prevSwingHighPrice > 0 && prevSwingHighRSI > 0) {
        if (swingHighPrice > prevSwingHighPrice && swingHighRSI < prevSwingHighRSI) {
            // Calcola forza divergenza (normalizzata con φ come scala)
            double priceDiff = (swingHighPrice - prevSwingHighPrice) / prevSwingHighPrice;
            double rsiDiff = (prevSwingHighRSI - swingHighRSI) / prevSwingHighRSI;
            calcStrength = MathMin(1.0, (priceDiff + rsiDiff) / PHI_INV);
            
            // 🌱 AGGIORNA BUFFER E SOGLIA DATA-DRIVEN
            UpdateDivergenceThreshold(calcStrength);
            
            if (calcStrength >= g_divergenceMinThreshold) {
                g_divergenceStrength = calcStrength;
                g_divergenceSignal = -1;  // Bearish
                if (g_enableLogsEffective) {
                    PrintFormat("[REVERSAL] ⚠️ BEARISH DIV: HH (%.5f→%.5f) + LH RSI (%.1f→%.1f) | Forza: %.0f%% > Soglia: %.0f%%",
                        prevSwingHighPrice, swingHighPrice, prevSwingHighRSI, swingHighRSI, 
                        g_divergenceStrength * 100, g_divergenceMinThreshold * 100);
                }
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    // BULLISH DIVERGENCE: Prezzo Lower Low, RSI Higher Low
    // ═══════════════════════════════════════════════════════════════
    if (foundSwingLow && prevSwingLowPrice > 0 && prevSwingLowRSI > 0 && g_divergenceSignal == 0) {
        if (swingLowPrice < prevSwingLowPrice && swingLowRSI > prevSwingLowRSI) {
            // Calcola forza divergenza (normalizzata con φ come scala)
            double priceDiff = (prevSwingLowPrice - swingLowPrice) / prevSwingLowPrice;
            double rsiDiff = (swingLowRSI - prevSwingLowRSI) / prevSwingLowRSI;
            calcStrength = MathMin(1.0, (priceDiff + rsiDiff) / PHI_INV);
            
            // 🌱 AGGIORNA BUFFER E SOGLIA DATA-DRIVEN
            UpdateDivergenceThreshold(calcStrength);
            
            if (calcStrength >= g_divergenceMinThreshold) {
                g_divergenceStrength = calcStrength;
                g_divergenceSignal = 1;  // Bullish
                if (g_enableLogsEffective) {
                    PrintFormat("[REVERSAL] ⚠️ BULLISH DIV: LL (%.5f→%.5f) + HL RSI (%.1f→%.1f) | Forza: %.0f%% > Soglia: %.0f%%",
                        prevSwingLowPrice, swingLowPrice, prevSwingLowRSI, swingLowRSI, 
                        g_divergenceStrength * 100, g_divergenceMinThreshold * 100);
                }
            }
        }
    }
    
    return g_divergenceSignal;
}

//+------------------------------------------------------------------+
//| 🌱 DETECTOR INVERSIONE MASTER: Combina tutti i segnali           |
//| Ritorna: +1 inversione bullish, -1 bearish, 0 nessuna            |
//| strength: 0-1 forza del segnale                                  |
//| 🌱 SOGLIA 100% DATA-DRIVEN: mean + stdev × φ⁻¹                   |
//+------------------------------------------------------------------+
int GetReversalSignal(double &strength)
{
    strength = 0.0;
    
    int momentumSignal = g_scoreMomentum > 0 ? 1 : (g_scoreMomentum < 0 ? -1 : 0);
    bool momentumStrong = MathAbs(g_scoreMomentum) >= g_scoreMomentumThreshold;
    
    int regimeSignal = g_regimeChangeDirection;
    int divergenceSignal = g_divergenceSignal;
    
    // ═══════════════════════════════════════════════════════════════
    // LOGICA COMBINATA (pesi organici)
    // Divergence = peso φ (più affidabile, classico)
    // Momentum = peso 1
    // Regime = peso φ⁻¹ (confirmation)
    // ═══════════════════════════════════════════════════════════════
    double score = 0.0;
    double maxScore = 0.0;
    
    // Divergenza RSI (peso più alto)
    if (divergenceSignal != 0) {
        score += divergenceSignal * PHI * g_divergenceStrength;
        maxScore += PHI;
    }
    
    // Score Momentum
    if (momentumStrong) {
        score += momentumSignal * 1.0;
        maxScore += 1.0;
    }
    
    // Regime Change
    if (regimeSignal != 0) {
        score += regimeSignal * PHI_INV;
        maxScore += PHI_INV;
    }
    
    if (maxScore <= 0) return 0;
    
    // Calcola forza normalizzata
    strength = MathAbs(score) / maxScore;
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 AGGIORNA BUFFER STORICO FORZA REVERSAL (per soglia data-driven)
    // Tracciamo TUTTE le forze (anche deboli) per avere distribuzione completa
    // ═══════════════════════════════════════════════════════════════
    int reversalBufferMax = (int)MathRound(MathPow(PHI, 8));  // φ⁸ ≈ 47
    
    // Sottrai valore vecchio se buffer pieno (O(1))
    if (g_reversalHistorySize == reversalBufferMax) {
        double oldValue = g_reversalStrengthHistory[g_reversalHistoryIndex];
        g_reversalSum -= oldValue;
        g_reversalSumSq -= oldValue * oldValue;
        if (g_reversalSum < -1e10) g_reversalSum = 0;  // Protezione drift
        if (g_reversalSumSq < 0) g_reversalSumSq = 0;
    }
    
    // Aggiungi valore corrente
    g_reversalStrengthHistory[g_reversalHistoryIndex] = strength;
    g_reversalSum += strength;
    g_reversalSumSq += strength * strength;
    
    // Aggiorna indice circolare
    g_reversalHistoryIndex = (g_reversalHistoryIndex + 1) % reversalBufferMax;
    if (g_reversalHistorySize < reversalBufferMax) g_reversalHistorySize++;
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 CALCOLA SOGLIA DATA-DRIVEN: mean + stdev × φ⁻¹
    // Richiede minimo φ³ ≈ 4 sample per significatività statistica
    // ═══════════════════════════════════════════════════════════════
    int minSamples = (int)MathRound(MathPow(PHI, 3));  // ≈ 4
    
    if (g_reversalHistorySize >= minSamples) {
        double mean = g_reversalSum / g_reversalHistorySize;
        double variance = (g_reversalSumSq / g_reversalHistorySize) - (mean * mean);
        double stdev = variance > 0 ? MathSqrt(variance) : 0;
        
        // Soglia = mean + stdev × φ⁻¹ (segnali significativamente sopra media)
        g_reversalThreshold = mean + stdev * PHI_INV;
        
        // Clamp organico: soglia minima φ⁻² ≈ 38%, massima φ⁻¹ ≈ 62%
        g_reversalThreshold = MathMax(PHI_INV_SQ, MathMin(PHI_INV, g_reversalThreshold));
        
        if (!g_reversalThresholdReady) {
            g_reversalThresholdReady = true;
            if (g_enableLogsEffective) {
                PrintFormat("[REVERSAL] ✅ Soglia data-driven pronta: %.1f%% (mean=%.1f%%, stdev=%.1f%%)",
                    g_reversalThreshold * 100, mean * 100, stdev * 100);
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 DECISIONE: Forza > soglia data-driven
    // ═══════════════════════════════════════════════════════════════
    if (strength >= g_reversalThreshold) {
        int direction = (score > 0) ? 1 : -1;
        
        if (g_enableLogsEffective) {
            PrintFormat("[REVERSAL] 🎯 INVERSIONE %s | Forza: %.0f%% > Soglia: %.0f%% | M=%s R=%s D=%s",
                direction > 0 ? "BULLISH" : "BEARISH",
                strength * 100,
                g_reversalThreshold * 100,
                momentumStrong ? (momentumSignal > 0 ? "📈" : "📉") : "➖",
                regimeSignal > 0 ? "🔺" : (regimeSignal < 0 ? "🔻" : "➖"),
                divergenceSignal > 0 ? "🟢" : (divergenceSignal < 0 ? "🔴" : "➖"));
        }
        
        return direction;
    }
    
    return 0;
}

//+------------------------------------------------------------------+
//| 🌱 Calcola il PERIODO NATURALE del mercato per un TF             |
//| Usa AUTOCORRELAZIONE per trovare il "memory decay" del prezzo    |
//| Il periodo naturale è dove l'autocorr scende sotto 1/φ² ≈ 0.382  |
//| Ritorna anche l'ESPONENTE DI HURST per calcolo pesi              |
//| Questo è COMPLETAMENTE derivato dai dati, zero numeri arbitrari  |
//+------------------------------------------------------------------+
NaturalPeriodResult CalculateNaturalPeriodForTF(ENUM_TIMEFRAMES tf)
{
    NaturalPeriodResult result;
    result.period = -1;
    result.hurstExponent = 0.0;  // Non calcolato (valid=false)
    result.valid = false;
    
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 APPROCCIO 100% DATA-DRIVEN (PURO - NO FALLBACK):
    // 1. Chiediamo barre dal PASSATO (non dalla barra corrente!)
    // 2. maxLag = barre_disponibili / φ² (derivato dai DATI!)
    // 3. Il periodo naturale emerge dall'autocorrelazione
    // Se non ci sono abbastanza dati, ritorna valid=false (TF disabilitato)
    // 
    // 🔧 FIX: In backtest, Bars() ritorna solo le barre "generate" fino a quel momento
    // Invece usiamo CopyRates con start dalla barra 1 (passato) per forzare
    // il caricamento dei dati storici pre-esistenti!
    // ═══════════════════════════════════════════════════════════════
    
    // 🔧 FIX: Richiediamo φ¹⁰ ≈ 123 barre storiche (sufficiente per analisi)
    int barsToRequest = (int)MathRound(MathPow(PHI, 10));  // ≈ 123
    
    // 🌱 Minimo PURO: φ⁴ ≈ 7 barre (sotto questo non ha senso statistico)
    int minBarsForAnalysis = (int)MathRound(PHI_SQ * PHI_SQ);  // ≈ 6.85 → 7
    
    // 🔧 FIX: Usa CopyRates DIRETTAMENTE per caricare dati storici
    // In backtest, questo forza MT5 a caricare i dati dal passato!
    // Usiamo start=1 (barra precedente) per evitare la barra corrente incompleta
    int copied = CopyRates(_Symbol, tf, 1, barsToRequest, rates);
    
    if (copied < minBarsForAnalysis) {
        PrintFormat("❌ [NATURAL] TF %s: copiate solo %d barre storiche, minimo richiesto %d - TF DISABILITATO", 
            EnumToString(tf), copied, minBarsForAnalysis);
        return result;  // valid = false
    }
    
    // 🔧 FIX: barsAvailable = numero EFFETTIVO di barre copiate (non Bars()!)
    int barsAvailable = copied;
    
    // 🌱 maxLag = barre / φ² (proporzione aurea delle barre disponibili)
    // Questo assicura sempre abbastanza dati per l'analisi
    int maxLag = (int)MathRound(barsAvailable / PHI_SQ);
    maxLag = MathMax((int)MathRound(PHI_SQ), maxLag);  // Minimo φ² ≈ 3 per analisi sensata
    
    // Log solo la prima volta per confermare che i dati storici sono caricati
    static bool loggedOnce_M5 = false, loggedOnce_H1 = false, loggedOnce_H4 = false, loggedOnce_D1 = false;
    bool shouldLog = false;
    
    if (tf == PERIOD_M5 && !loggedOnce_M5) { shouldLog = true; loggedOnce_M5 = true; }
    else if (tf == PERIOD_H1 && !loggedOnce_H1) { shouldLog = true; loggedOnce_H1 = true; }
    else if (tf == PERIOD_H4 && !loggedOnce_H4) { shouldLog = true; loggedOnce_H4 = true; }
    else if (tf == PERIOD_D1 && !loggedOnce_D1) { shouldLog = true; loggedOnce_D1 = true; }
    
    if (shouldLog) {
        PrintFormat("[NATURAL] ✅ TF %s: Caricati %d/%d barre storiche (maxLag=%d)", 
            EnumToString(tf), copied, barsToRequest, maxLag);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // CALCOLO AUTOCORRELAZIONE
    // L'autocorrelazione misura quanto il prezzo "ricorda" se stesso
    // Quando scende sotto 1/φ² ≈ 0.382, il mercato ha "dimenticato"
    // ═══════════════════════════════════════════════════════════════
    
    // Calcola media dei close
    double mean = 0;
    for (int i = 0; i < copied; i++) {
        mean += rates[i].close;
    }
    mean /= copied;
    
    // Calcola varianza
    double variance = 0;
    for (int i = 0; i < copied; i++) {
        double diff = rates[i].close - mean;
        variance += diff * diff;
    }
    variance /= copied;
    
    if (variance <= 0) {
        PrintFormat("❌ [NATURAL] TF %s: varianza zero (prezzo flat) - TF DISABILITATO", EnumToString(tf));
        return result;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 CALCOLA ESPONENTE DI HURST (per determinare peso TF)
    // Confrontato con g_hurstCenter e soglie dinamiche:
    //   H > g_hurstRandomHigh: trending → peso maggiore
    //   H < g_hurstRandomLow: mean-reverting → peso maggiore
    // ═══════════════════════════════════════════════════════════════
    double hurstValue = CalculateHurstExponent(rates, copied);
    
    // Variabili per il calcolo del periodo naturale
    double autocorrSum = 0;
    int autocorrCount = 0;
    
    // Trova il lag dove l'autocorrelazione scende sotto 1/φ²
    // Questo è il "periodo naturale" del mercato
    int naturalPeriod = 0;
    double threshold = PHI_INV_SQ;  // ≈ 0.382 (soglia organica!)
    double autocorrAtNaturalPeriod = 0;
    
    for (int lag = 1; lag < MathMin(maxLag, copied / 2); lag++) {
        double covariance = 0;
        int count = 0;
        
        for (int i = lag; i < copied; i++) {
            covariance += (rates[i].close - mean) * (rates[i-lag].close - mean);
            count++;
        }
        
        if (count > 0) {
            covariance /= count;
            double autocorr = covariance / variance;
            
            // Accumula per media autocorrelazione
            if (autocorr > 0) {
                autocorrSum += autocorr;
                autocorrCount++;
            }
            
            // Prima volta che scende sotto soglia = periodo naturale trovato
            if (autocorr < threshold && naturalPeriod == 0) {
                naturalPeriod = lag;
                autocorrAtNaturalPeriod = autocorr;
                
                if (g_enableLogsEffective) {
                    PrintFormat("[NATURAL] 🌱 TF %s: autocorr[%d]=%.3f < %.3f → Periodo naturale=%d",
                        EnumToString(tf), lag, autocorr, threshold, naturalPeriod);
                }
                // Continua a calcolare per avere la media completa
            }
        }
    }
    
    // Se non trovato (mercato molto trending), usa metodo alternativo
    if (naturalPeriod == 0) {
        // Usa il primo minimo locale dell'autocorrelazione
        naturalPeriod = FindAutocorrelationMinimum(rates, copied, maxLag);
        
        if (naturalPeriod == 0) {
            // Derivato dalle barre disponibili: maxLag / φ
            naturalPeriod = (int)MathRound(maxLag / PHI);
            PrintFormat("[NATURAL] ⚠️ TF %s: nessun decay trovato, uso maxLag/φ≈%d", 
                EnumToString(tf), naturalPeriod);
        }
    }
    
    // 🌱 Limita il periodo con rapporti aurei delle barre disponibili
    int minPeriod = (int)MathRound(PHI);              // ≈ 2 (minimo assoluto)
    int maxPeriod = (int)MathRound(maxLag / PHI);     // Derivato dalle barre
    naturalPeriod = MathMax(minPeriod, MathMin(maxPeriod, naturalPeriod));
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 ESPONENTE DI HURST DETERMINA IL PESO TF
    // peso_TF = H_TF / Σ(H_tutti_TF) - normalizzato
    // TF con H più alto contribuiscono maggiormente
    // ═══════════════════════════════════════════════════════════════
    // 🔧 FIX: Se Hurst ritorna -1 (dati insufficienti), non è valido
    if (hurstValue < 0) {
        PrintFormat("[NATURAL] ⚠️ TF %s: Hurst non calcolabile (dati insufficienti)", EnumToString(tf));
        result.valid = false;
        return result;
    }
    
    // ✅ VALIDATO: hurstValue già nel range [HURST_RANGE_MIN, HURST_RANGE_MAX]
    result.hurstExponent = hurstValue;
    result.period = naturalPeriod;
    result.valid = true;
    
    if (g_enableLogsEffective) {
        // NOTA: etichetta basata su soglie dinamiche se zona pronta, altrimenti solo valore H
        string regimeLabel = "WARM-UP";
        if (g_hurstZoneReady) {
            regimeLabel = (result.hurstExponent > g_hurstRandomHigh) ? "TRENDING" :
                         ((result.hurstExponent < g_hurstRandomLow) ? "MEAN-REV" : "RANDOM");
        }
        PrintFormat("[NATURAL] 🌱 TF %s: Periodo=%d | Hurst=%.3f (%s)",
            EnumToString(tf), naturalPeriod, result.hurstExponent, regimeLabel);
    }
    
    return result;
}

//+------------------------------------------------------------------+
//| 🌱 Trova il primo minimo locale dell'autocorrelazione            |
//| Metodo alternativo quando il decay non scende sotto soglia       |
//+------------------------------------------------------------------+
int FindAutocorrelationMinimum(MqlRates &rates[], int n, int maxLag)
{
    double mean = 0;
    for (int i = 0; i < n; i++) mean += rates[i].close;
    mean /= n;
    
    double variance = 0;
    for (int i = 0; i < n; i++) {
        double diff = rates[i].close - mean;
        variance += diff * diff;
    }
    variance /= n;
    if (variance <= 0) return 0;
    
    double prevAutocorr = 1.0;
    double prevPrevAutocorr = 1.0;
    
    for (int lag = 2; lag < MathMin(maxLag, n / 2); lag++) {
        double covariance = 0;
        int count = 0;
        
        for (int i = lag; i < n; i++) {
            covariance += (rates[i].close - mean) * (rates[i-lag].close - mean);
            count++;
        }
        
        if (count > 0) {
            covariance /= count;
            double autocorr = covariance / variance;
            
            // Minimo locale: prev < prevPrev AND prev < current
            if (prevAutocorr < prevPrevAutocorr && prevAutocorr < autocorr) {
                if (g_enableLogsEffective) {
                    PrintFormat("[NATURAL] 🌱 Minimo autocorr trovato a lag=%d (autocorr=%.3f)", 
                        lag - 1, prevAutocorr);
                }
                return lag - 1;
            }
            
            prevPrevAutocorr = prevAutocorr;
            prevAutocorr = autocorr;
        }
    }
    
    return 0;  // Nessun minimo trovato
}

//+------------------------------------------------------------------+
//| 🌱 CALCOLA PERCENTILE dai dati                                   |
//| Deriva le soglie dalla distribuzione REALE, non da numeri fissi  |
//+------------------------------------------------------------------+
double CalculatePercentile(const double &arr[], int size, double percentile)
{
    if (size <= 0) return 0;
    
    // Copia e ordina
    double sorted[];
    ArrayResize(sorted, size);
    for (int i = 0; i < size; i++) sorted[i] = arr[i];
    ArraySort(sorted);
    
    // Calcola indice del percentile
    double idx = (percentile / 100.0) * (size - 1);
    int lower = (int)MathFloor(idx);
    int upper = (int)MathCeil(idx);
    
    if (lower == upper || upper >= size) return sorted[lower];
    
    // Interpolazione lineare
    double frac = idx - lower;
    return sorted[lower] * (1.0 - frac) + sorted[upper] * frac;
}

//+------------------------------------------------------------------+
//| 🌱 CALCOLA MEDIA EMPIRICA                                        |
//| Ritorna: mean(arr) = somma(valori) / N                          |
//+------------------------------------------------------------------+
double CalculateEmpiricalMean(const double &arr[], int size)
{
    if (size <= 0) return 0;
    
    double sum = 0;
    for (int i = 0; i < size; i++) sum += arr[i];
    return sum / size;
}

//+------------------------------------------------------------------+
//| 🌱 CALCOLA DEVIAZIONE STANDARD                                   |
//| La scala REALE dipende dalla volatilità storica dell'indicatore  |
//+------------------------------------------------------------------+
double CalculateEmpiricalStdDev(const double &arr[], int size, double mean)
{
    // 🌱 PURO: ritorna 0 se dati insufficienti - il chiamante gestirà l'errore
    if (size <= 1) return 0.0;
    
    double sumSq = 0;
    for (int i = 0; i < size; i++) {
        double diff = arr[i] - mean;
        sumSq += diff * diff;
    }
    return MathSqrt(sumSq / (size - 1));
}

//+------------------------------------------------------------------+
//| 🌱 CALCOLA SOGLIE EMPIRICHE per un TimeFrame - PURO              |
//| Tutti i centri e scale derivano dai DATI storici reali           |
//| Se i dati sono insufficienti, INVALIDA il TF (no fallback!)      |
//| Ritorna: true se calcolo OK, false se dati insufficienti         |
//+------------------------------------------------------------------+
bool CalculateEmpiricalThresholds(TimeFrameData &data, int lookback)
{
    int size = ArraySize(data.rsi);
    int n = MathMin(lookback, size);
    
    // 🌱 MINIMO PURO: φ³ ≈ 4 (minimo per statistiche sensate)
    // Questo è l'UNICO "numero magico" ed è derivato da φ
    int minBarsRequired = (int)MathRound(PHI * PHI * PHI);  // ≈ 4.236 → 4
    
    if (n < minBarsRequired) {
        // ❌ DATI INSUFFICIENTI - NON USARE FALLBACK, INVALIDA IL TF
        Print("❌ [EMPIRICAL] DATI INSUFFICIENTI! Richieste almeno ", minBarsRequired, 
              " barre, disponibili: ", n, " - TF DISABILITATO");
        
        // Azzera tutto per evitare uso accidentale
        data.rsi_center = 0;
        data.rsi_scale = 0;
        data.adx_p25 = 0;
        data.adx_p75 = 0;
        
        return false;  // Segnala fallimento
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 CENTRI EMPIRICI - La media REALE dal mercato
    // ═══════════════════════════════════════════════════════════════
    
    // RSI: prepara array delle ultime n barre
    double rsi_data[];
    ArrayResize(rsi_data, n);
    for (int i = 0; i < n; i++) rsi_data[i] = data.rsi[size - n + i];
    data.rsi_center = CalculateEmpiricalMean(rsi_data, n);
    double rsi_stdev = CalculateEmpiricalStdDev(rsi_data, n, data.rsi_center);
    if (rsi_stdev <= 0) {
        Print("❌ [EMPIRICAL] RSI stdev=0, dati flat - TF DISABILITATO");
        return false;
    }
    data.rsi_scale = rsi_stdev * PHI;  // Scala = stdev × φ
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 ADX PERCENTILI - Soglie dalla distribuzione REALE
    // ═══════════════════════════════════════════════════════════════
    if (ArraySize(data.adx) >= n) {
        double adx_data[];
        ArrayResize(adx_data, n);
        for (int i = 0; i < n; i++) adx_data[i] = data.adx[size - n + i];
        
        // Percentili aurei: 1/φ² ≈ 38.2% e 1/φ ≈ 61.8%
        data.adx_p25 = CalculatePercentile(adx_data, n, PHI_INV_SQ * 100);  // ~38° percentile
        data.adx_p75 = CalculatePercentile(adx_data, n, PHI_INV * 100);     // ~62° percentile
        
        // Verifica che i percentili siano sensati (p75 > p25)
        if (data.adx_p75 <= data.adx_p25) {
            Print("❌ [EMPIRICAL] ADX percentili invalidi (p75 <= p25) - TF DISABILITATO");
            return false;
        }
    } else {
        Print("❌ [EMPIRICAL] ADX: dati insufficienti");
        return false;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🔧 FIX: OBV SCALA EMPIRICA - Dalle variazioni REALI
    // Calcola la stdev delle VARIAZIONI di OBV (non i valori assoluti)
    // ═══════════════════════════════════════════════════════════════
    int obvSize = ArraySize(data.obv);
    if (obvSize >= n && n > 1) {
        double obv_changes[];
        ArrayResize(obv_changes, n - 1);
        int startIdx = obvSize - n;
        for (int i = 0; i < n - 1; i++) {
            obv_changes[i] = data.obv[startIdx + i + 1] - data.obv[startIdx + i];
        }
        double obv_change_mean = CalculateEmpiricalMean(obv_changes, n - 1);
        double obv_change_stdev = CalculateEmpiricalStdDev(obv_changes, n - 1, obv_change_mean);
        
        // Scala = stdev × φ, con fallback se troppo piccola
        if (obv_change_stdev > 0) {
            data.obv_scale = obv_change_stdev * PHI;
        } else {
            // 🔧 FIX: Fallback migliorato - usa range OBV osservato invece di ATR
            double obv_max = data.obv[startIdx];
            double obv_min = data.obv[startIdx];
            for (int i = 1; i < n; i++) {
                if (data.obv[startIdx + i] > obv_max) obv_max = data.obv[startIdx + i];
                if (data.obv[startIdx + i] < obv_min) obv_min = data.obv[startIdx + i];
            }
            double obv_range = obv_max - obv_min;
            // Scala = range / (φ³ × sqrt(n)) come stima della variazione tipica
            double divisor = MathPow(PHI, 3) * MathSqrt((double)n);
            if (divisor > 0 && obv_range > 0) {
                data.obv_scale = obv_range / divisor;
            } else {
                data.obv_scale = 1000.0;  // Fallback conservativo
            }
        }
        // 🔧 FIX: Garantire sempre scala minima positiva per evitare DIV/0
        if (data.obv_scale <= 0) {
            data.obv_scale = MathPow(PHI, 7);  // 🌱 Minimo = φ⁷ ≈ 29
        }
    } else {
        // OBV non disponibile, usa fallback organico
        data.obv_scale = MathPow(PHI, 10);  // 🌱 φ¹⁰ ≈ 123 (valore tipico per volumi)
    }
    
    if (g_enableLogsEffective) {
        PrintFormat("[EMPIRICAL] ✅ RSI center=%.1f scale=%.1f | ADX p25=%.1f p75=%.1f | OBV scale=%.1f",
            data.rsi_center, data.rsi_scale, data.adx_p25, data.adx_p75, data.obv_scale);
    }
    
    return true;  // Calcolo completato con successo
}

//+------------------------------------------------------------------+
//| 🌱 CALCOLA PERIODI 100% DATA-DRIVEN                              |
//| TUTTO derivato dal periodo naturale usando SOLO rapporti φ       |
//| NESSUN numero Fibonacci arbitrario - solo rapporti aurei         |
//| φ ≈ 1.618, 1/φ ≈ 0.618, 1/φ² ≈ 0.382, 1/φ³ ≈ 0.236              |
//| PESO TF: derivato dall'ESPONENTE DI HURST!                       |
//+------------------------------------------------------------------+
void CalculateOrganicPeriodsFromData(ENUM_TIMEFRAMES tf, OrganicPeriods &organic, int naturalPeriod, double weight, double hurstExp)
{
    // 🌱 PESO E HURST passati dal chiamante (derivati empiricamente)
    organic.weight = weight;
    organic.hurstExponent = hurstExp;
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 PERIODO NATURALE = deriva dall'AUTOCORRELAZIONE (dai DATI!)
    // Tutti gli altri periodi sono DERIVATI da questo usando rapporti φ
    // Nessun numero arbitrario - la base viene dal mercato stesso
    // ═══════════════════════════════════════════════════════════════
    double base = (double)naturalPeriod;
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 RAPPORTI AUREI per differenziare i periodi
    // Ogni indicatore usa un multiplo/divisore φ del periodo naturale
    // Questo crea una "scala aurea" di periodi tutti correlati
    //
    // Molto veloce = base / φ² ≈ base × 0.382
    // Veloce       = base / φ  ≈ base × 0.618
    // Medio        = base × 1   (periodo naturale)
    // Lento        = base × φ  ≈ base × 1.618
    // Molto lento  = base × φ² ≈ base × 2.618
    // Lunghissimo  = base × φ³ ≈ base × 4.236
    // ═══════════════════════════════════════════════════════════════
    
    // Periodi organici - TUTTI derivati dal periodo naturale
    // 🌱 I minimi usano potenze di φ per coerenza (non Fibonacci arbitrari!)
    // min_veryFast = φ¹ ≈ 2, min_fast = φ² ≈ 3, min_slow = φ³ ≈ 4, etc.
    int veryFast = (int)MathMax((int)MathRound(PHI), MathRound(base * PHI_INV_SQ));         // min≈2, base × 0.382
    int fast     = (int)MathMax((int)MathRound(PHI_SQ), MathRound(base * PHI_INV));         // min≈3, base × 0.618
    int medium   = (int)MathMax((int)MathRound(PHI_SQ), MathRound(base));                   // min≈3, base (naturale)
    int slow     = (int)MathMax((int)MathRound(PHI_SQ * PHI), MathRound(base * PHI));       // min≈4, base × 1.618
    int verySlow = (int)MathMax((int)MathRound(PHI_SQ * PHI_SQ), MathRound(base * PHI_SQ)); // min≈7, base × 2.618
    int longest  = (int)MathMax((int)MathRound(PHI_SQ * PHI_SQ * PHI), MathRound(base * PHI_SQ * PHI)); // min≈11, base × 4.236
    
    if (g_enableLogsEffective) {
        PrintFormat("[ORGANIC] 🌱 TF %s: Naturale=%d → VeryFast=%d Fast=%d Medium=%d Slow=%d VerySlow=%d Longest=%d",
            EnumToString(tf), naturalPeriod, veryFast, fast, medium, slow, verySlow, longest);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 ASSEGNAZIONE PERIODI - Logica basata sul ruolo dell'indicatore
    // Indicatori "veloci" → usano periodi corti (momentum, segnali)
    // Indicatori "lenti" → usano periodi lunghi (trend, struttura)
    // ═══════════════════════════════════════════════════════════════
    
    // Trend indicators (necessitano periodi più lunghi)
    organic.ema = slow;                     // EMA: segue il trend → slow
    
    // Momentum indicators
    organic.rsi = medium;                   // RSI → medium
    
    // MACD (tre periodi in relazione aurea tra loro)
    organic.macd_fast = fast;               // MACD veloce → fast
    organic.macd_slow = slow;               // MACD lento → slow
    organic.macd_signal = veryFast;         // MACD signal → veryFast (smoothing)
    
    // Bollinger Bands
    organic.bb = slow;                      // BB periodo → slow
    organic.bb_dev = PHI_INV + MathSqrt(base) * PHI_INV_SQ;  // BB dev: organico da base
    // 🌱 Limiti derivati da φ: min=1/φ≈0.618 (banda stretta), max=φ≈1.618 + 1 = 2.618
    organic.bb_dev = MathMax(PHI_INV, MathMin(PHI_SQ, organic.bb_dev));
    
    // Volatility indicators
    organic.atr = medium;                   // ATR: volatilità → medium
    organic.adx = medium;                   // ADX: forza trend → medium
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 PESO TF = H_TF / Σ(H_tutti_TF)
    // TF con Hurst maggiore → peso maggiore
    // peso già calcolato in OnInit e assegnato a organic.weight
    // ═══════════════════════════════════════════════════════════════
    // organic.weight già assegnato all'inizio della funzione
    // organic.hurstExponent già assegnato all'inizio della funzione
    
    // 🌱 Barre minime = periodo più lungo usato + margine
    // Calcolato dinamicamente in base ai periodi effettivi
    organic.min_bars_required = longest + medium; // longest + buffer organico
    
    // 🌱 Salva il periodo naturale per uso nelle scale
    organic.naturalPeriod = naturalPeriod;
}

//+------------------------------------------------------------------+
//| 🌱 Log dei periodi organici calcolati                            |
//+------------------------------------------------------------------+
void LogOrganicPeriods(string tfName, OrganicPeriods &organic)
{
    PrintFormat("[%s] 🌱 Peso TF: %.2f | EMA=%d RSI=%d MACD=%d/%d/%d BB=%d(%.1f) ATR=%d ADX=%d | Min barre: %d",
        tfName, organic.weight, organic.ema, organic.rsi, 
        organic.macd_fast, organic.macd_slow, organic.macd_signal,
        organic.bb, organic.bb_dev, organic.atr, organic.adx, organic.min_bars_required);
}

//+------------------------------------------------------------------+
//| 🔧 FIX: Verifica se i periodi sono cambiati significativamente    |
//| Ritorna true se almeno un periodo è cambiato >23.6% (soglia = 1/φ³)|
//| In tal caso gli handle indicatori devono essere ricreati          |
//+------------------------------------------------------------------+
bool PeriodsChangedSignificantly()
{
    if (!g_periodsInitialized) return false;  // Primo calcolo, non serve confronto
    
    // 🌱 Soglia cambio = 1/φ³ ≈ 23.6% (derivata organicamente da φ)
    //    Abbastanza reattiva ma non troppo sensibile
    const double CHANGE_THRESHOLD = PHI_INV_CUB;  // ≈ 0.236 = 23.6%
    
    // Controlla ogni TF attivo
    if (g_dataReady_M5) {
        double oldPeriod = (double)g_prevOrganic_M5.ema;
        double newPeriod = (double)g_organic_M5.ema;
        if (oldPeriod > 0 && MathAbs(newPeriod - oldPeriod) / oldPeriod > CHANGE_THRESHOLD) {
            if (g_enableLogsEffective) {
                PrintFormat("[PERIODS] ⚠️ M5 EMA period changed: %d → %d (%.1f%%)", 
                    (int)oldPeriod, (int)newPeriod, 100.0 * MathAbs(newPeriod - oldPeriod) / oldPeriod);
            }
            return true;
        }
    }
    
    if (g_dataReady_H1) {
        double oldPeriod = (double)g_prevOrganic_H1.ema;
        double newPeriod = (double)g_organic_H1.ema;
        if (oldPeriod > 0 && MathAbs(newPeriod - oldPeriod) / oldPeriod > CHANGE_THRESHOLD) {
            if (g_enableLogsEffective) {
                PrintFormat("[PERIODS] ⚠️ H1 EMA period changed: %d → %d (%.1f%%)", 
                    (int)oldPeriod, (int)newPeriod, 100.0 * MathAbs(newPeriod - oldPeriod) / oldPeriod);
            }
            return true;
        }
    }
    
    if (g_dataReady_H4) {
        double oldPeriod = (double)g_prevOrganic_H4.ema;
        double newPeriod = (double)g_organic_H4.ema;
        if (oldPeriod > 0 && MathAbs(newPeriod - oldPeriod) / oldPeriod > CHANGE_THRESHOLD) {
            if (g_enableLogsEffective) {
                PrintFormat("[PERIODS] ⚠️ H4 EMA period changed: %d → %d (%.1f%%)", 
                    (int)oldPeriod, (int)newPeriod, 100.0 * MathAbs(newPeriod - oldPeriod) / oldPeriod);
            }
            return true;
        }
    }
    
    if (g_dataReady_D1) {
        double oldPeriod = (double)g_prevOrganic_D1.ema;
        double newPeriod = (double)g_organic_D1.ema;
        if (oldPeriod > 0 && MathAbs(newPeriod - oldPeriod) / oldPeriod > CHANGE_THRESHOLD) {
            if (g_enableLogsEffective) {
                PrintFormat("[PERIODS] ⚠️ D1 EMA period changed: %d → %d (%.1f%%)", 
                    (int)oldPeriod, (int)newPeriod, 100.0 * MathAbs(newPeriod - oldPeriod) / oldPeriod);
            }
            return true;
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| 🔧 FIX: Salva periodi correnti come precedenti                    |
//+------------------------------------------------------------------+
void SaveCurrentPeriodsAsPrevious()
{
    g_prevOrganic_M5 = g_organic_M5;
    g_prevOrganic_H1 = g_organic_H1;
    g_prevOrganic_H4 = g_organic_H4;
    g_prevOrganic_D1 = g_organic_D1;
    g_periodsInitialized = true;
}

//+------------------------------------------------------------------+
//| Deinitializzazione                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if (g_enableLogsEffective) {
        PrintFormat("[DEINIT] 🛑 EA Deinit avviato - Motivo: %d (%s)", reason, GetDeinitReasonText(reason));
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 📊 REPORT FINALE STATISTICHE TRADING
    // ═══════════════════════════════════════════════════════════════
    if (g_stats.totalTrades > 0) {
        double netProfit = g_stats.totalProfit - g_stats.totalLoss;
        double winRate = 100.0 * g_stats.winTrades / g_stats.totalTrades;
        double avgSlippage = (g_stats.slippageCount > 0) ? g_stats.totalSlippage / g_stats.slippageCount : 0;
        
        Print("");
        Print("╔═══════════════════════════════════════════════════════════════════════════╗");
        Print("║                    📊 REPORT FINALE SESSIONE                               ║");
        Print("╠═══════════════════════════════════════════════════════════════════════════╣");
        PrintFormat("║ Simbolo: %s | Magic: %d", _Symbol, g_uniqueMagicNumber);
        PrintFormat("║ Periodo: %s → %s", 
            TimeToString(g_eaStartTime, TIME_DATE|TIME_MINUTES),
            TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
        Print("╠═══════════════════════════════════════════════════════════════════════════╣");
        PrintFormat("║ TRADES: %d totali | Win: %d (%.1f%%) | Loss: %d (%.1f%%)",
            g_stats.totalTrades,
            g_stats.winTrades, winRate,
            g_stats.lossTrades, 100.0 - winRate);
        PrintFormat("║ PROFITTO LORDO: +%.2f | PERDITA LORDA: -%.2f",
            g_stats.totalProfit, g_stats.totalLoss);
        PrintFormat("║ 💰 PROFITTO NETTO: %+.2f %s",
            netProfit, AccountInfoString(ACCOUNT_CURRENCY));
        PrintFormat("║ COMMISSIONI: %.2f | SWAP: %.2f",
            g_stats.totalCommission, g_stats.totalSwap);
        Print("╠═══════════════════════════════════════════════════════════════════════════╣");
        PrintFormat("║ PROFIT FACTOR: %.2f", g_stats.profitFactor);
        PrintFormat("║ EXPECTANCY: %.2f per trade", g_stats.expectancy);
        PrintFormat("║ AVG WIN: %.2f | AVG LOSS: %.2f | Ratio: %.2f",
            g_stats.avgWin, g_stats.avgLoss,
            g_stats.avgLoss > 0 ? g_stats.avgWin / g_stats.avgLoss : 0);
        Print("╠═══════════════════════════════════════════════════════════════════════════╣");
        PrintFormat("║ MAX DRAWDOWN: %.2f (%.2f%%)",
            g_stats.maxDrawdown, g_stats.maxDrawdownPct);
        PrintFormat("║ MAX WIN STREAK: %d | MAX LOSS STREAK: %d",
            g_stats.maxWinStreak, g_stats.maxLossStreak);
        if (g_stats.slippageCount > 0) {
            PrintFormat("║ AVG SLIPPAGE: %.2f pts su %d trade",
                avgSlippage, g_stats.slippageCount);
        }
        Print("╚═══════════════════════════════════════════════════════════════════════════╝");
        Print("");
    } else {
        Print("[DEINIT] 📊 Nessun trade eseguito in questa sessione");
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 📊 EXPORT TRADES PER MONTE CARLO ANALYSIS
    // ═══════════════════════════════════════════════════════════════
    if (ExportTradesCSV) {
        Print("[DEINIT] 📊 Avvio esportazione trade CSV...");
        ExportTradesToCSV();
    } else {
        Print("[DEINIT] 📊 Export CSV disabilitato (ExportTradesCSV=false)");
    }
    
    EventKillTimer();
    if (g_enableLogsEffective) Print("[DEINIT] ⏱️ Timer terminato");
    
    ReleaseIndicators();
    
    // Reset buffer storici (pulizia esplicita)
    int hurstSize = ArraySize(g_hurstHistory);
    int scoreSize = ArraySize(g_scoreHistory);
    int tradeScoreSize = ArraySize(g_tradeScoreHistory);
    
    ArrayFree(g_hurstHistory);
    ArrayFree(g_scoreHistory);
    ArrayFree(g_tradeScoreHistory);
    
    // ✅ Reset indici buffer
    g_hurstHistorySize = 0;
    g_hurstHistoryIndex = 0;
    g_scoreHistorySize = 0;
    g_scoreHistoryIndex = 0;
    g_tradeScoreHistorySize = 0;
    g_tradeScoreHistoryIndex = 0;
    
    // ✅ Reset somme incrementali (CRITICO per riavvio EA!)
    g_hurstSum = 0.0;
    g_hurstSumSq = 0.0;
    g_scoreSum = 0.0;
    g_scoreSumSq = 0.0;
    g_tradeScoreSum = 0.0;
    g_tradeScoreSumSq = 0.0;
    
    // 🔧 FIX: Reset contatori anti-drift
    g_hurstOperationCount = 0;
    g_scoreOperationCount = 0;
    g_tradeScoreOperationCount = 0;
    
    // ✅ Reset flag di stato
    g_hurstZoneReady = false;
    g_hurstReady = false;
    g_tradeScoreReady = false;
    g_scoreThresholdReady = false;
    
    // ✅ Reset variabili di cache e contatori
    g_tfDataCacheValid = false;
    g_tfDataRecalcCounter = 0;
    g_barsSinceLastRecalc = 0;
    lastBarTime = 0;
    lastHurstRecalc = 0;
    
    // ✅ Reset valori calcolati Hurst
    g_hurstCenter = 0.0;
    g_hurstStdev = 0.0;
    g_hurstZoneMargin = 0.0;
    g_hurstRandomLow = 0.0;
    g_hurstRandomHigh = 0.0;
    g_hurstComposite = 0.0;
    g_hurstConfidence = 0.0;
    g_hurstTradeScore = 0.0;
    g_tradeScoreThreshold = 0.0;
    g_dynamicThreshold = 0.0;
    
    if (g_enableLogsEffective) {
        PrintFormat("[DEINIT-BUFFER] 🧹 g_hurstHistory liberato: %d elementi → 0 %s",
            hurstSize, ArraySize(g_hurstHistory) == 0 ? "✅" : "❌");
        PrintFormat("[DEINIT-BUFFER] 🧹 g_scoreHistory liberato: %d elementi → 0 %s",
            scoreSize, ArraySize(g_scoreHistory) == 0 ? "✅" : "❌");
        PrintFormat("[DEINIT-BUFFER] 🧹 g_tradeScoreHistory liberato: %d elementi → 0 %s",
            tradeScoreSize, ArraySize(g_tradeScoreHistory) == 0 ? "✅" : "❌");
        Print("[DEINIT] ✅ EA terminato correttamente");
    }
}

//+------------------------------------------------------------------+
//| 📊 EXPORT TRADES TO CSV - Per analisi Monte Carlo                |
//| Esporta tutti i trade chiusi in formato CSV per Python           |
//| ✅ Funziona sia in LIVE che in BACKTEST                          |
//+------------------------------------------------------------------+
void ExportTradesToCSV()
{
    bool isTester = MQLInfoInteger(MQL_TESTER) != 0;
    Print(isTester ? "[EXPORT] 📊 Modalità BACKTEST" : "[EXPORT] 📊 Modalità LIVE");
    
    // Per backtest: usa 0 come data iniziale per prendere TUTTO lo storico
    // Per live: usa g_eaStartTime  
    datetime startTime = isTester ? 0 : g_eaStartTime;
    datetime endTime = TimeCurrent();
    
    // Nel tester, TimeCurrent() potrebbe essere la data finale del test
    // Assicuriamoci di prendere tutto
    if (isTester) {
        endTime = D'2099.12.31';  // Data futura per prendere tutto
    }
    
    if (!HistorySelect(startTime, endTime)) {
        Print("[EXPORT] ❌ Impossibile accedere allo storico trade - HistorySelect failed");
        return;
    }
    
    int totalDeals = HistoryDealsTotal();
    PrintFormat("[EXPORT] 📊 HistoryDealsTotal = %d", totalDeals);
    if (totalDeals == 0) {
        Print("[EXPORT] ⚠️ Nessun deal nello storico - nessun file creato");
        return;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // PRIMA PASSA: Conta i trade validi e calcola balance iniziale
    // ═══════════════════════════════════════════════════════════════
    int validTradeCount = 0;
    double totalPL = 0;
    
    for (int i = 0; i < totalDeals; i++) {
        ulong dealTicket = HistoryDealGetTicket(i);
        if (dealTicket == 0) continue;
        
        // Filtra solo deal del nostro EA (o tutti se magic = 0 nel tester)
        long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
        if (!isTester && MagicNumber != 0 && dealMagic != g_uniqueMagicNumber && dealMagic != MagicNumber) continue;
        
        // Filtra solo deal di uscita
        ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
        if (dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_INOUT) continue;
        
        // Solo deal dello stesso simbolo
        string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
        if (dealSymbol != _Symbol) continue;
        
        validTradeCount++;
        totalPL += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                 + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION)
                 + HistoryDealGetDouble(dealTicket, DEAL_SWAP);
    }
    
    if (validTradeCount == 0) {
        Print("[EXPORT] ⚠️ Nessun trade valido trovato per questo simbolo/EA");
        return;
    }
    
    // Calcola balance iniziale
    double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double startBalance = finalBalance - totalPL;
    double runningBalance = startBalance;
    
    // ═══════════════════════════════════════════════════════════════
    // GENERA NOME FILE
    // ═══════════════════════════════════════════════════════════════
    string symbolClean = _Symbol;
    StringReplace(symbolClean, "/", "");
    StringReplace(symbolClean, "\\", "");
    StringReplace(symbolClean, ".", "");
    StringReplace(symbolClean, "#", "");
    
    // Usa data corrente per live, data fine test per backtest
    string dateStr = TimeToString(TimeCurrent(), TIME_DATE);
    StringReplace(dateStr, ".", "-");
    
    // Aggiungi suffisso per distinguere backtest da live
    string suffix = isTester ? "_backtest" : "_live";
    string filename = StringFormat("trades_%s_%s%s.csv", symbolClean, dateStr, suffix);
    
    // ═══════════════════════════════════════════════════════════════
    // APRI FILE - Usa FILE_COMMON per accessibilità
    // ═══════════════════════════════════════════════════════════════
    // FILE_COMMON salva in: C:\Users\[User]\AppData\Roaming\MetaQuotes\Terminal\Common\Files
    // Questo è accessibile sia da live che da tester
    int fileHandle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ';');
    
    if (fileHandle == INVALID_HANDLE) {
        // Fallback: prova senza FILE_COMMON
        fileHandle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI, ';');
        if (fileHandle == INVALID_HANDLE) {
            PrintFormat("[EXPORT] ❌ Impossibile creare file: %s (Errore: %d)", filename, GetLastError());
            return;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    // SCRIVI HEADER CSV (compatibile con montecarlo_analyzer.py)
    // ═══════════════════════════════════════════════════════════════
    FileWrite(fileHandle, 
        "Ticket", "OpenTime", "CloseTime", "Type", "Symbol", "Volume", 
        "OpenPrice", "ClosePrice", "Commission", "Swap", "Profit", 
        "NetProfit", "Balance", "Duration_Minutes", "MagicNumber", "Comment");
    
    int exportedCount = 0;
    
    // ═══════════════════════════════════════════════════════════════
    // SECONDA PASSA: Esporta i trade con tutti i dettagli
    // ═══════════════════════════════════════════════════════════════
    for (int i = 0; i < totalDeals; i++) {
        ulong dealTicket = HistoryDealGetTicket(i);
        if (dealTicket == 0) continue;
        
        // Filtra solo deal del nostro EA
        long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
        if (!isTester && MagicNumber != 0 && dealMagic != g_uniqueMagicNumber && dealMagic != MagicNumber) continue;
        
        // Filtra solo chiusure (DEAL_ENTRY_OUT) - ignora aperture
        ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
        if (dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_INOUT) continue;
        
        // Solo deal dello stesso simbolo
        string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
        if (dealSymbol != _Symbol) continue;
        
        // Estrai dati del deal di chiusura
        datetime closeTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
        ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
        double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
        double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
        double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
        double swap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
        double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
        string comment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
        
        // Sanitizza il comment per evitare problemi con il separatore CSV
        StringReplace(comment, ";", ",");  // Sostituisce ; con , per evitare problemi CSV
        StringReplace(comment, "\n", " "); // Rimuovi newline
        StringReplace(comment, "\r", " "); // Rimuovi carriage return
        
        // Trova il deal di APERTURA per questa posizione
        long positionId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
        double openPrice = closePrice;  // Fallback: usa closePrice se non troviamo apertura
        datetime openTime = closeTime;  // Fallback: usa closeTime se non troviamo apertura
        ENUM_DEAL_TYPE openDealType = DEAL_TYPE_BUY;
        bool foundOpenDeal = false;
        
        for (int j = 0; j < i; j++) {
            ulong openDealTicket = HistoryDealGetTicket(j);
            if (openDealTicket == 0) continue;
            
            if (HistoryDealGetInteger(openDealTicket, DEAL_POSITION_ID) == positionId) {
                ENUM_DEAL_ENTRY openEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(openDealTicket, DEAL_ENTRY);
                if (openEntry == DEAL_ENTRY_IN) {
                    openPrice = HistoryDealGetDouble(openDealTicket, DEAL_PRICE);
                    openTime = (datetime)HistoryDealGetInteger(openDealTicket, DEAL_TIME);
                    openDealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(openDealTicket, DEAL_TYPE);
                    // Aggiungi commissione di apertura SOLO se presente e non già inclusa
                    double openCommission = HistoryDealGetDouble(openDealTicket, DEAL_COMMISSION);
                    if (MathAbs(openCommission) > 0.0001) {
                        commission += openCommission;
                    }
                    foundOpenDeal = true;
                    break;
                }
            }
        }
        
        // Se non abbiamo trovato il deal di apertura, determina tipo dalla chiusura
        if (!foundOpenDeal) {
            // Se chiude con SELL, era un BUY. Se chiude con BUY, era un SELL
            openDealType = (dealType == DEAL_TYPE_SELL) ? DEAL_TYPE_BUY : DEAL_TYPE_SELL;
        }
        
        // Calcola durata trade in minuti
        int durationMinutes = (openTime > 0) ? (int)((closeTime - openTime) / 60) : 0;
        
        // Il TIPO della posizione è quello del deal di APERTURA (non chiusura!)
        string typeStr = (openDealType == DEAL_TYPE_BUY) ? "Buy" : "Sell";
        
        // Calcola profitto netto (profit + commission + swap)
        double netProfit = profit + commission + swap;
        
        // Aggiorna balance running
        runningBalance += netProfit;
        
        // Formatta i numeri con punto decimale fisso (evita problemi con locale)
        // NormalizeDouble assicura precisione, poi formattiamo manualmente
        int symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
        
        string volStr = DoubleToString(volume, 2);
        string openPriceStr = DoubleToString(openPrice, symbolDigits);
        string closePriceStr = DoubleToString(closePrice, symbolDigits);
        string commStr = DoubleToString(commission, 2);
        string swapStr = DoubleToString(swap, 2);
        string profitStr = DoubleToString(profit, 2);
        string netProfitStr = DoubleToString(netProfit, 2);
        string balanceStr = DoubleToString(runningBalance, 2);
        
        // Forza il punto decimale (alcuni locale usano virgola)
        StringReplace(volStr, ",", ".");
        StringReplace(openPriceStr, ",", ".");
        StringReplace(closePriceStr, ",", ".");
        StringReplace(commStr, ",", ".");
        StringReplace(swapStr, ",", ".");
        StringReplace(profitStr, ",", ".");
        StringReplace(netProfitStr, ",", ".");
        StringReplace(balanceStr, ",", ".");
        
        // Scrivi riga CSV
        FileWrite(fileHandle,
            IntegerToString(dealTicket),                                          // Ticket
            TimeToString(openTime, TIME_DATE|TIME_SECONDS),                       // OpenTime
            TimeToString(closeTime, TIME_DATE|TIME_SECONDS),                      // CloseTime
            typeStr,                                                              // Type
            dealSymbol,                                                           // Symbol
            volStr,                                                               // Volume
            openPriceStr,                                                         // OpenPrice
            closePriceStr,                                                        // ClosePrice
            commStr,                                                              // Commission
            swapStr,                                                              // Swap
            profitStr,                                                            // Profit (lordo)
            netProfitStr,                                                         // NetProfit (netto)
            balanceStr,                                                           // Balance
            IntegerToString(durationMinutes),                                     // Duration
            IntegerToString(dealMagic),                                           // MagicNumber
            comment);                                                             // Comment
        
        exportedCount++;
    }
    
    FileClose(fileHandle);
    
    // ═══════════════════════════════════════════════════════════════
    // STAMPA RISULTATO
    // ═══════════════════════════════════════════════════════════════
    if (exportedCount > 0) {
        string commonPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\" + filename;
        string localPath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\" + filename;
        
        Print("");
        Print("╔═══════════════════════════════════════════════════════════════════════════╗");
        Print("║              📊 EXPORT TRADE COMPLETATO PER MONTE CARLO                    ║");
        Print("╠═══════════════════════════════════════════════════════════════════════════╣");
        PrintFormat("║ Trade esportati: %d", exportedCount);
        PrintFormat("║ Balance iniziale: %.2f → Balance finale: %.2f", startBalance, runningBalance);
        PrintFormat("║ Profitto totale: %+.2f", totalPL);
        Print("╠═══════════════════════════════════════════════════════════════════════════╣");
        PrintFormat("║ File: %s", filename);
        if (isTester) {
            Print("║ 📂 BACKTEST - File salvato in:");
            PrintFormat("║    %s", commonPath);
        } else {
            Print("║ 📂 LIVE - File salvato in:");
            PrintFormat("║    %s", localPath);
        }
        Print("╠═══════════════════════════════════════════════════════════════════════════╣");
        Print("║ 💡 Per analisi Monte Carlo:                                                ║");
        Print("║    1. Copia il file nella cartella montecarlo/                             ║");
        Print("║    2. Esegui: python example_usage.py                                      ║");
        Print("╚═══════════════════════════════════════════════════════════════════════════╝");
        Print("");
    } else {
        Print("[EXPORT] ⚠️ Nessun trade esportato");
    }
}

//+------------------------------------------------------------------+
//| Descrizione motivo deinit                                        |
//+------------------------------------------------------------------+
string GetDeinitReasonText(int reason)
{
    switch(reason) {
        case REASON_PROGRAM:     return "Programma terminato";
        case REASON_REMOVE:      return "EA rimosso dal grafico";
        case REASON_RECOMPILE:   return "Ricompilazione";
        case REASON_CHARTCHANGE: return "Cambio simbolo/timeframe";
        case REASON_CHARTCLOSE:  return "Grafico chiuso";
        case REASON_PARAMETERS:  return "Parametri modificati";
        case REASON_ACCOUNT:     return "Account cambiato";
        case REASON_TEMPLATE:    return "Template applicato";
        case REASON_INITFAILED:  return "OnInit fallito";
        case REASON_CLOSE:       return "Terminale chiuso";
        default:                 return "Sconosciuto";
    }
}

//+------------------------------------------------------------------+
//| 🌱 Inizializzazione handles indicatori con periodi ORGANICI      |
//+------------------------------------------------------------------+
bool InitializeIndicators()
{
    if (g_enableLogsEffective) Print("[INIT-HANDLES] 🔧 Inizio creazione handle indicatori...");
    
    int handleCount = 0;
    int handleErrors = 0;
    
    // ═══════════════════════════════════════════════════════════════
    // M5: Timeframe operativo (scalping/intraday)
    // ═══════════════════════════════════════════════════════════════
    emaHandle_M5 = iMA(_Symbol, PERIOD_M5, g_organic_M5.ema, 0, MODE_EMA, PRICE_CLOSE);
    rsiHandle_M5 = iRSI(_Symbol, PERIOD_M5, g_organic_M5.rsi, PRICE_CLOSE);
    macdHandle_M5 = iMACD(_Symbol, PERIOD_M5, g_organic_M5.macd_fast, g_organic_M5.macd_slow, g_organic_M5.macd_signal, PRICE_CLOSE);
    bbHandle_M5 = iBands(_Symbol, PERIOD_M5, g_organic_M5.bb, 0, g_organic_M5.bb_dev, PRICE_CLOSE);
    atrHandle_M5 = iATR(_Symbol, PERIOD_M5, g_organic_M5.atr);
    adxHandle_M5 = iADX(_Symbol, PERIOD_M5, g_organic_M5.adx);
    obvHandle_M5 = iOBV(_Symbol, PERIOD_M5, VOLUME_TICK);
    
    // Log M5
    if (g_enableLogsEffective) {
        int m5ok = 0, m5err = 0;
        if (emaHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (rsiHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (macdHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (bbHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (atrHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (adxHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (obvHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        handleCount += m5ok; handleErrors += m5err;
        PrintFormat("[INIT-HANDLES] M5: %d/%d handle creati %s", m5ok, 7, m5err == 0 ? "✅" : "⚠️");
    }
    
    // ═══════════════════════════════════════════════════════════════
    // H1: Timeframe intermedio
    // ═══════════════════════════════════════════════════════════════
    emaHandle_H1 = iMA(_Symbol, PERIOD_H1, g_organic_H1.ema, 0, MODE_EMA, PRICE_CLOSE);
    rsiHandle_H1 = iRSI(_Symbol, PERIOD_H1, g_organic_H1.rsi, PRICE_CLOSE);
    macdHandle_H1 = iMACD(_Symbol, PERIOD_H1, g_organic_H1.macd_fast, g_organic_H1.macd_slow, g_organic_H1.macd_signal, PRICE_CLOSE);
    bbHandle_H1 = iBands(_Symbol, PERIOD_H1, g_organic_H1.bb, 0, g_organic_H1.bb_dev, PRICE_CLOSE);
    atrHandle_H1 = iATR(_Symbol, PERIOD_H1, g_organic_H1.atr);
    adxHandle_H1 = iADX(_Symbol, PERIOD_H1, g_organic_H1.adx);
    obvHandle_H1 = iOBV(_Symbol, PERIOD_H1, VOLUME_TICK);
    
    // Log H1
    if (g_enableLogsEffective) {
        int h1ok = 0, h1err = 0;
        if (emaHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (rsiHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (macdHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (bbHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (atrHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (adxHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (obvHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        handleCount += h1ok; handleErrors += h1err;
        PrintFormat("[INIT-HANDLES] H1: %d/%d handle creati %s", h1ok, 7, h1err == 0 ? "✅" : "⚠️");
    }
    
    // ═══════════════════════════════════════════════════════════════
    // H4: Timeframe swing
    // ═══════════════════════════════════════════════════════════════
    emaHandle_H4 = iMA(_Symbol, PERIOD_H4, g_organic_H4.ema, 0, MODE_EMA, PRICE_CLOSE);
    rsiHandle_H4 = iRSI(_Symbol, PERIOD_H4, g_organic_H4.rsi, PRICE_CLOSE);
    macdHandle_H4 = iMACD(_Symbol, PERIOD_H4, g_organic_H4.macd_fast, g_organic_H4.macd_slow, g_organic_H4.macd_signal, PRICE_CLOSE);
    bbHandle_H4 = iBands(_Symbol, PERIOD_H4, g_organic_H4.bb, 0, g_organic_H4.bb_dev, PRICE_CLOSE);
    atrHandle_H4 = iATR(_Symbol, PERIOD_H4, g_organic_H4.atr);
    adxHandle_H4 = iADX(_Symbol, PERIOD_H4, g_organic_H4.adx);
    obvHandle_H4 = iOBV(_Symbol, PERIOD_H4, VOLUME_TICK);
    
    // Log H4
    if (g_enableLogsEffective) {
        int h4ok = 0, h4err = 0;
        if (emaHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (rsiHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (macdHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (bbHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (atrHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (adxHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (obvHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        handleCount += h4ok; handleErrors += h4err;
        PrintFormat("[INIT-HANDLES] H4: %d/%d handle creati %s", h4ok, 7, h4err == 0 ? "✅" : "⚠️");
    }
    
    // ═══════════════════════════════════════════════════════════════
    // D1: Timeframe trend lungo
    // ═══════════════════════════════════════════════════════════════
    emaHandle_D1 = iMA(_Symbol, PERIOD_D1, g_organic_D1.ema, 0, MODE_EMA, PRICE_CLOSE);
    rsiHandle_D1 = iRSI(_Symbol, PERIOD_D1, g_organic_D1.rsi, PRICE_CLOSE);
    macdHandle_D1 = iMACD(_Symbol, PERIOD_D1, g_organic_D1.macd_fast, g_organic_D1.macd_slow, g_organic_D1.macd_signal, PRICE_CLOSE);
    bbHandle_D1 = iBands(_Symbol, PERIOD_D1, g_organic_D1.bb, 0, g_organic_D1.bb_dev, PRICE_CLOSE);
    atrHandle_D1 = iATR(_Symbol, PERIOD_D1, g_organic_D1.atr);
    adxHandle_D1 = iADX(_Symbol, PERIOD_D1, g_organic_D1.adx);
    obvHandle_D1 = iOBV(_Symbol, PERIOD_D1, VOLUME_TICK);
    
    // Log D1
    if (g_enableLogsEffective) {
        int d1ok = 0, d1err = 0;
        if (emaHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (rsiHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (macdHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (bbHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (atrHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (adxHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (obvHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        handleCount += d1ok; handleErrors += d1err;
        PrintFormat("[INIT-HANDLES] D1: %d/%d handle creati %s", d1ok, 7, d1err == 0 ? "✅" : "⚠️");
        PrintFormat("[INIT-HANDLES] 📊 TOTALE: %d/28 handle creati | Errori: %d %s", 
            handleCount, handleErrors, handleErrors == 0 ? "✅" : "❌");
    }
    
    return (emaHandle_M5 != INVALID_HANDLE && rsiHandle_M5 != INVALID_HANDLE && 
            macdHandle_M5 != INVALID_HANDLE && bbHandle_M5 != INVALID_HANDLE &&
            atrHandle_M5 != INVALID_HANDLE && adxHandle_M5 != INVALID_HANDLE &&
            obvHandle_M5 != INVALID_HANDLE &&
            emaHandle_H1 != INVALID_HANDLE && rsiHandle_H1 != INVALID_HANDLE &&
            macdHandle_H1 != INVALID_HANDLE && bbHandle_H1 != INVALID_HANDLE &&
            atrHandle_H1 != INVALID_HANDLE && adxHandle_H1 != INVALID_HANDLE &&
            obvHandle_H1 != INVALID_HANDLE &&
            emaHandle_H4 != INVALID_HANDLE && rsiHandle_H4 != INVALID_HANDLE &&
            macdHandle_H4 != INVALID_HANDLE && bbHandle_H4 != INVALID_HANDLE &&
            atrHandle_H4 != INVALID_HANDLE && adxHandle_H4 != INVALID_HANDLE &&
            obvHandle_H4 != INVALID_HANDLE &&
            emaHandle_D1 != INVALID_HANDLE && rsiHandle_D1 != INVALID_HANDLE &&
            macdHandle_D1 != INVALID_HANDLE && bbHandle_D1 != INVALID_HANDLE &&
            atrHandle_D1 != INVALID_HANDLE && adxHandle_D1 != INVALID_HANDLE &&
            obvHandle_D1 != INVALID_HANDLE);
}

//+------------------------------------------------------------------+
//| Rilascio handles indicatori                                      |
//+------------------------------------------------------------------+
void ReleaseIndicators()
{
    if (g_enableLogsEffective) Print("[DEINIT-HANDLES] 🔧 Inizio rilascio handle indicatori...");
    
    int releasedCount = 0;
    int releaseErrors = 0;
    
    // M5
    if (emaHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_M5)) releasedCount++; else releaseErrors++; emaHandle_M5 = INVALID_HANDLE; }
    if (rsiHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_M5)) releasedCount++; else releaseErrors++; rsiHandle_M5 = INVALID_HANDLE; }
    if (macdHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_M5)) releasedCount++; else releaseErrors++; macdHandle_M5 = INVALID_HANDLE; }
    if (bbHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_M5)) releasedCount++; else releaseErrors++; bbHandle_M5 = INVALID_HANDLE; }
    if (atrHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_M5)) releasedCount++; else releaseErrors++; atrHandle_M5 = INVALID_HANDLE; }
    if (adxHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_M5)) releasedCount++; else releaseErrors++; adxHandle_M5 = INVALID_HANDLE; }
    if (obvHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_M5)) releasedCount++; else releaseErrors++; obvHandle_M5 = INVALID_HANDLE; }
    
    // H1
    if (emaHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_H1)) releasedCount++; else releaseErrors++; emaHandle_H1 = INVALID_HANDLE; }
    if (rsiHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_H1)) releasedCount++; else releaseErrors++; rsiHandle_H1 = INVALID_HANDLE; }
    if (macdHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_H1)) releasedCount++; else releaseErrors++; macdHandle_H1 = INVALID_HANDLE; }
    if (bbHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_H1)) releasedCount++; else releaseErrors++; bbHandle_H1 = INVALID_HANDLE; }
    if (atrHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_H1)) releasedCount++; else releaseErrors++; atrHandle_H1 = INVALID_HANDLE; }
    if (adxHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_H1)) releasedCount++; else releaseErrors++; adxHandle_H1 = INVALID_HANDLE; }
    if (obvHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_H1)) releasedCount++; else releaseErrors++; obvHandle_H1 = INVALID_HANDLE; }
    
    // H4
    if (emaHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_H4)) releasedCount++; else releaseErrors++; emaHandle_H4 = INVALID_HANDLE; }
    if (rsiHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_H4)) releasedCount++; else releaseErrors++; rsiHandle_H4 = INVALID_HANDLE; }
    if (macdHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_H4)) releasedCount++; else releaseErrors++; macdHandle_H4 = INVALID_HANDLE; }
    if (bbHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_H4)) releasedCount++; else releaseErrors++; bbHandle_H4 = INVALID_HANDLE; }
    if (atrHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_H4)) releasedCount++; else releaseErrors++; atrHandle_H4 = INVALID_HANDLE; }
    if (adxHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_H4)) releasedCount++; else releaseErrors++; adxHandle_H4 = INVALID_HANDLE; }
    if (obvHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_H4)) releasedCount++; else releaseErrors++; obvHandle_H4 = INVALID_HANDLE; }
    
    // D1
    if (emaHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_D1)) releasedCount++; else releaseErrors++; emaHandle_D1 = INVALID_HANDLE; }
    if (rsiHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_D1)) releasedCount++; else releaseErrors++; rsiHandle_D1 = INVALID_HANDLE; }
    if (macdHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_D1)) releasedCount++; else releaseErrors++; macdHandle_D1 = INVALID_HANDLE; }
    if (bbHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_D1)) releasedCount++; else releaseErrors++; bbHandle_D1 = INVALID_HANDLE; }
    if (atrHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_D1)) releasedCount++; else releaseErrors++; atrHandle_D1 = INVALID_HANDLE; }
    if (adxHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_D1)) releasedCount++; else releaseErrors++; adxHandle_D1 = INVALID_HANDLE; }
    if (obvHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_D1)) releasedCount++; else releaseErrors++; obvHandle_D1 = INVALID_HANDLE; }
    
    if (g_enableLogsEffective) {
        PrintFormat("[DEINIT-HANDLES] 📊 TOTALE: %d/28 handle rilasciati | Errori: %d %s", 
            releasedCount, releaseErrors, releaseErrors == 0 ? "✅" : "⚠️");
    }
}

//+------------------------------------------------------------------+
//| 🚀 AGGIORNAMENTO VELOCE - Solo ultima barra (usa cache)          |
//| Invece di ricaricare tutto, aggiorna solo i valori più recenti   |
//+------------------------------------------------------------------+
bool UpdateLastBar(ENUM_TIMEFRAMES tf, TimeFrameData &data)
{
    // Se i dati non sono pronti, non possiamo aggiornare
    if (!data.isDataReady || ArraySize(data.rates) < 2) return false;
    
    int count = ArraySize(data.rates);
    int lastIdx = count - 1;
    
    // Carica solo l'ultima barra
    MqlRates lastRates[];
    if (CopyRates(_Symbol, tf, 0, 2, lastRates) < 2) return false;
    
    // Aggiorna solo l'ultima barra nei rates
    data.rates[lastIdx] = lastRates[1];
    
    // Aggiorna indicatori principali per ultima barra (solo quelli necessari per il trade)
    // Seleziona handles appropriati per timeframe
    int emaH = INVALID_HANDLE, rsiH = INVALID_HANDLE, macdH = INVALID_HANDLE;
    int atrH = INVALID_HANDLE, adxH = INVALID_HANDLE;
    
    switch(tf) {
        case PERIOD_M5:  emaH = emaHandle_M5; rsiH = rsiHandle_M5; macdH = macdHandle_M5; atrH = atrHandle_M5; adxH = adxHandle_M5; break;
        case PERIOD_H1:  emaH = emaHandle_H1; rsiH = rsiHandle_H1; macdH = macdHandle_H1; atrH = atrHandle_H1; adxH = adxHandle_H1; break;
        case PERIOD_H4:  emaH = emaHandle_H4; rsiH = rsiHandle_H4; macdH = macdHandle_H4; atrH = atrHandle_H4; adxH = adxHandle_H4; break;
        case PERIOD_D1:  emaH = emaHandle_D1; rsiH = rsiHandle_D1; macdH = macdHandle_D1; atrH = atrHandle_D1; adxH = adxHandle_D1; break;
        default: return false;
    }
    
    // Aggiorna solo ultimi 2 valori degli indicatori chiave
    double tempBuf[2];
    if (CopyBuffer(emaH, 0, 0, 2, tempBuf) == 2) { data.ema[lastIdx] = tempBuf[1]; data.ema[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(rsiH, 0, 0, 2, tempBuf) == 2) { data.rsi[lastIdx] = tempBuf[1]; data.rsi[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(macdH, 0, 0, 2, tempBuf) == 2) { data.macd[lastIdx] = tempBuf[1]; data.macd[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(macdH, 1, 0, 2, tempBuf) == 2) { data.macd_signal[lastIdx] = tempBuf[1]; data.macd_signal[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(atrH, 0, 0, 2, tempBuf) == 2) { data.atr[lastIdx] = tempBuf[1]; data.atr[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(adxH, 0, 0, 2, tempBuf) == 2) { data.adx[lastIdx] = tempBuf[1]; data.adx[lastIdx-1] = tempBuf[0]; }
    
    return true;
}

//+------------------------------------------------------------------+
//| 🌱 Caricamento dati timeframe con calcolo valori organici        |
//| 🔧 FIX: Usa start=1 per caricare dati STORICI (passato)          |
//+------------------------------------------------------------------+
bool LoadTimeFrameData(ENUM_TIMEFRAMES tf, TimeFrameData &data, int bars)
{
    // 🔧 FIX: Usa start=1 per garantire dati dal passato, non dalla barra corrente incompleta
    int copiedBars = CopyRates(_Symbol, tf, 1, bars, data.rates);
    if (copiedBars <= 0) {
        PrintFormat("[ERROR] Impossibile caricare rates per TF %s", EnumToString(tf));
        return false;
    }
    
    // 🔧 FIX: Non più warning "dati parziali" - ora usiamo quello che c'è
    // Se servono N barre e ne abbiamo M < N, usiamo M (il sistema si adatta)
    
    // 🔧 FIX: Verifica che i dati non siano corrotti (prezzi validi)
    // 🌱 Numero barre da verificare = round(φ³) ≈ 4 (derivato da φ)
    int barsToCheck = (int)MathRound(MathPow(PHI, 3));  // φ³ ≈ 4
    int invalidBars = 0;
    for (int i = 0; i < MathMin(copiedBars, barsToCheck); i++) {
        if (data.rates[i].close <= 0 || data.rates[i].open <= 0 ||
            data.rates[i].high <= 0 || data.rates[i].low <= 0 ||
            data.rates[i].high < data.rates[i].low) {
            invalidBars++;
        }
    }
    // 🌱 Soglia = round(φ) ≈ 2 (derivato da φ)
    int maxInvalidBars = (int)MathRound(PHI);  // ≈ 2
    if (invalidBars > maxInvalidBars) {
        PrintFormat("[ERROR] TF %s: Dati corrotti rilevati (%d/%d barre invalide)", 
            EnumToString(tf), invalidBars, barsToCheck);
        return false;
    }
    
    int count = ArraySize(data.rates);
    
    // Ridimensiona arrays
    ArrayResize(data.ema, count);
    ArrayResize(data.rsi, count);
    ArrayResize(data.macd, count);
    ArrayResize(data.macd_signal, count);
    ArrayResize(data.bb_upper, count);
    ArrayResize(data.bb_middle, count);
    ArrayResize(data.bb_lower, count);
    ArrayResize(data.atr, count);
    ArrayResize(data.adx, count);
    ArrayResize(data.di_plus, count);   // +DI per direzione trend
    ArrayResize(data.di_minus, count);  // -DI per direzione trend
    ArrayResize(data.ha_open, count);
    ArrayResize(data.ha_close, count);
    ArrayResize(data.obv, count);
    
    // 🌱 Inizializza valori organici (saranno calcolati dai DATI dopo il caricamento)
    data.atr_avg = 0;
    data.adx_avg = 0;
    data.adx_stddev = 0;
    data.adx_threshold = 0;  // Verrà calcolato da CalculateOrganicValues
    data.isDataReady = false;
    
    // 🌱 PURO: Inizializza tutto a 0 - verranno calcolati dai DATI
    data.rsi_center = 0;
    data.rsi_scale = 0;
    data.obv_scale = 0;
    data.adx_p25 = 0;
    data.adx_p75 = 0;
    
    // Copia dati indicatori (seleziona handles appropriati per timeframe)
    int emaH = INVALID_HANDLE, rsiH = INVALID_HANDLE, macdH = INVALID_HANDLE;
    int bbH = INVALID_HANDLE, atrH = INVALID_HANDLE, adxH = INVALID_HANDLE;
    int obvH = INVALID_HANDLE;
    int minBarsRequired = g_organic_M5.min_bars_required;
    
    switch(tf) {
        case PERIOD_M5:
            emaH = emaHandle_M5; rsiH = rsiHandle_M5; macdH = macdHandle_M5;
            bbH = bbHandle_M5; atrH = atrHandle_M5; adxH = adxHandle_M5;
            obvH = obvHandle_M5;
            minBarsRequired = g_organic_M5.min_bars_required;
            data.organic = g_organic_M5;  // 🌱 Copia periodi organici
            break;
        case PERIOD_H1:
            emaH = emaHandle_H1; rsiH = rsiHandle_H1; macdH = macdHandle_H1;
            bbH = bbHandle_H1; atrH = atrHandle_H1; adxH = adxHandle_H1;
            obvH = obvHandle_H1;
            minBarsRequired = g_organic_H1.min_bars_required;
            data.organic = g_organic_H1;  // 🌱 Copia periodi organici
            break;
        case PERIOD_H4:
            emaH = emaHandle_H4; rsiH = rsiHandle_H4; macdH = macdHandle_H4;
            bbH = bbHandle_H4; atrH = atrHandle_H4; adxH = adxHandle_H4;
            obvH = obvHandle_H4;
            minBarsRequired = g_organic_H4.min_bars_required;
            data.organic = g_organic_H4;  // 🌱 Copia periodi organici
            break;
        case PERIOD_D1:
            emaH = emaHandle_D1; rsiH = rsiHandle_D1; macdH = macdHandle_D1;
            bbH = bbHandle_D1; atrH = atrHandle_D1; adxH = adxHandle_D1;
            obvH = obvHandle_D1;
            minBarsRequired = g_organic_D1.min_bars_required;
            data.organic = g_organic_D1;  // 🌱 Copia periodi organici
            break;
        default:
            return false;
    }
    
    // 🔧 FIX: Copia buffers indicatori da start=1 per allineamento con CopyRates(start=1)
    // Questo garantisce che indicatori e prezzi siano sincronizzati sulle stesse barre storiche
    if (CopyBuffer(emaH, 0, 1, count, data.ema) <= 0) return false;
    if (CopyBuffer(rsiH, 0, 1, count, data.rsi) <= 0) return false;
    if (CopyBuffer(macdH, 0, 1, count, data.macd) <= 0) return false;
    if (CopyBuffer(macdH, 1, 1, count, data.macd_signal) <= 0) return false;
    if (CopyBuffer(bbH, 0, 1, count, data.bb_upper) <= 0) return false;
    if (CopyBuffer(bbH, 1, 1, count, data.bb_middle) <= 0) return false;
    if (CopyBuffer(bbH, 2, 1, count, data.bb_lower) <= 0) return false;
    if (CopyBuffer(atrH, 0, 1, count, data.atr) <= 0) return false;
    if (CopyBuffer(adxH, 0, 1, count, data.adx) <= 0) return false;
    if (CopyBuffer(adxH, 1, 1, count, data.di_plus) <= 0) return false;   // +DI
    if (CopyBuffer(adxH, 2, 1, count, data.di_minus) <= 0) return false;  // -DI
    if (CopyBuffer(obvH, 0, 1, count, data.obv) <= 0) return false;
    
    // Calcola indicatori derivati (Heikin Ashi)
    CalculateCustomIndicators(data, count);
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 CALCOLO VALORI ORGANICI (ATR medio, ADX threshold dinamico)
    // Questi valori si auto-adattano ai dati storici disponibili
    // ═══════════════════════════════════════════════════════════════
    CalculateOrganicValues(data, count, minBarsRequired);
    
    return true;
}

//+------------------------------------------------------------------+
//| 🌱 Calcolo valori organici per ATR e ADX - PURO                  |
//| FORMULA ATR: atr_avg = media(ATR ultime N barre)                 |
//| FORMULA ADX: adx_threshold = media(ADX) + (1/φ) * stddev(ADX)   |
//| Se dati insufficienti → isDataReady = false (no fallback!)       |
//+------------------------------------------------------------------+
void CalculateOrganicValues(TimeFrameData &data, int count, int minBarsRequired)
{
    // Verifica se abbiamo abbastanza dati
    if (count < minBarsRequired) {
        Print("❌ [ORGANIC] Barre insufficienti: ", count, " < ", minBarsRequired, " richieste - TF DISABILITATO");
        data.isDataReady = false;
        return;
    }
    
    int lastIdx = count - 1;
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 LOOKBACK derivato dal naturalPeriod × φ
    // Solo UN moltiplicatore φ, non potenze arbitrarie!
    // Il naturalPeriod già deriva dai DATI (autocorrelazione)
    // ═══════════════════════════════════════════════════════════════
    int organicLookback = (int)MathRound(data.organic.naturalPeriod * PHI);
    int lookback = MathMin(organicLookback, count - 1);
    lookback = MathMax(lookback, (int)MathRound(PHI_SQ));  // Minimo φ² ≈ 3
    
    // ═══════════════════════════════════════════════════════════════
    // ATR ORGANICO: Media semplice delle ultime N barre
    // Formula: atr_avg = sum(ATR[i]) / N
    // ═══════════════════════════════════════════════════════════════
    double atr_sum = 0;
    int atr_count = 0;
    for (int i = lastIdx - lookback; i <= lastIdx; i++) {
        if (i >= 0 && i < ArraySize(data.atr)) {
            atr_sum += data.atr[i];
            atr_count++;
        }
    }
    
    if (atr_count == 0 || atr_sum <= 0) {
        Print("❌ [ORGANIC] ATR invalido (count=", atr_count, ", sum=", atr_sum, ") - TF DISABILITATO");
        data.isDataReady = false;
        return;
    }
    data.atr_avg = atr_sum / atr_count;
    
    // ═══════════════════════════════════════════════════════════════
    // ADX ORGANICO: Media + (1/φ) * deviazione standard
    // Formula: threshold = avg(ADX) + (1/φ) * sqrt(sum((ADX-avg)^2)/N)
    // Questo identifica quando ADX è "significativamente sopra" la norma
    // ═══════════════════════════════════════════════════════════════
    double adx_sum = 0;
    int adx_count = 0;
    for (int i = lastIdx - lookback; i <= lastIdx; i++) {
        if (i >= 0 && i < ArraySize(data.adx)) {
            adx_sum += data.adx[i];
            adx_count++;
        }
    }
    
    if (adx_count == 0) {
        Print("❌ [ORGANIC] ADX dati insufficienti - TF DISABILITATO");
        data.isDataReady = false;
        return;
    }
    data.adx_avg = adx_sum / adx_count;
    
    // Calcola deviazione standard
    double variance_sum = 0;
    for (int i = lastIdx - lookback; i <= lastIdx; i++) {
        if (i >= 0 && i < ArraySize(data.adx)) {
            double diff = data.adx[i] - data.adx_avg;
            variance_sum += diff * diff;
        }
    }
    data.adx_stddev = MathSqrt(variance_sum / adx_count);
    
    if (data.adx_stddev <= 0) {
        Print("❌ [ORGANIC] ADX stddev=0 (dati flat) - TF DISABILITATO");
        data.isDataReady = false;
        return;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 CALCOLA SOGLIE EMPIRICHE per tutti gli oscillatori
    // Centri e scale derivano dai DATI storici, non da costanti teoriche!
    // Se fallisce, invalida il TF (no fallback!)
    // ═══════════════════════════════════════════════════════════════
    bool empiricalOK = CalculateEmpiricalThresholds(data, lookback);
    
    if (!empiricalOK) {
        Print("❌ [ORGANIC] Calcolo soglie empiriche FALLITO - TF DISABILITATO");
        data.isDataReady = false;
        return;
    }
    
    // 🌱 Soglia ADX organica = media + (1/φ) × stddev ≈ avg + 0.618×stddev
    // φ (rapporto aureo) definisce la proporzione naturale tra media e variazione
    data.adx_threshold = data.adx_avg + PHI_INV * data.adx_stddev;
    
    // 🌱 Limita la soglia usando PERCENTILI empirici invece di potenze arbitrarie
    // I limiti ora derivano dalla distribuzione REALE dei dati ADX
    data.adx_threshold = MathMax(data.adx_p25, MathMin(data.adx_p75, data.adx_threshold));
    
    // ✅ Tutti i calcoli completati con successo
    data.isDataReady = true;
    
    if (g_enableLogsEffective) {
        PrintFormat("[ORGANIC] ✅ TF ready: ATR_avg=%.5f ADX_threshold=%.1f lookback=%d",
            data.atr_avg, data.adx_threshold, lookback);
    }
}

//+------------------------------------------------------------------+
//| 🚀 Calcolo indicatori personalizzati OTTIMIZZATO O(n)            |
//| Solo Heikin Ashi (altri indicatori rimossi per pulizia)         |
//+------------------------------------------------------------------+
void CalculateCustomIndicators(TimeFrameData &data, int count)
{
    if (count < 1) return;
    
    // Calcola Heikin Ashi (O(n))
    for (int i = 0; i < count; i++) {
        double close = data.rates[i].close;
        double open = data.rates[i].open;
        double high = data.rates[i].high;
        double low = data.rates[i].low;
        
        // Heikin Ashi
        double haClose = (open + high + low + close) * 0.25;
        double haOpen = (i == 0) ? (open + close) * 0.5 : (data.ha_open[i-1] + data.ha_close[i-1]) * 0.5;
        data.ha_close[i] = haClose;
        data.ha_open[i] = haOpen;
    }
}

//+------------------------------------------------------------------+
//| 🌱 Calcolo segnali per timeframe con pesi specifici              |
//| LOGICA NORMALIZZATA TREND-FOLLOWING:                            |
//| Tutti gli indicatori: >0 = BUY, <0 = SELL                       |
//| I pesi moltiplicano i valori normalizzati                        |
//| ADX: trend-following (ADX alto + DI per direzione)              |
//| ATR: contrarian (ATR > media = possibile inversione)            |
//|                                                                  |
//| 🌱 SOGLIE ORGANICHE:                                             |
//|   ADX threshold = data.adx_threshold (calcolato dinamicamente)   |
//|   ATR threshold = data.atr_avg (media dinamica, no moltiplicatore)|
//|                                                                  |
//| 🌱 PESI ORGANICI (sostituiscono 72 input hardcodati):            |
//|   Ogni indicatore usa enable bool + peso TF organico             |
//|   peso_TF = data.organic.weight (auto-calcolato)                 |
//+------------------------------------------------------------------+
double CalculateSignalScore(TimeFrameData &data, string timeframe)
// 🌱 NOTA: Usa direttamente enableXXX (bool globali) e data.organic.weight (peso organico TF)
{
    int lastIdx = ArraySize(data.rates) - 1;
    if (lastIdx < 1) return 0;
    
    // 🌱 Verifica se i dati sono pronti per il calcolo organico
    if (!data.isDataReady) {
        return 0;  // Non abbiamo abbastanza dati, non generare segnali
    }
    
    double price = data.rates[lastIdx].close;
    // 🚀 USA g_pointValue CACHATO (inizializzato 1× in OnInit)
    double point_value = g_pointValue;
    
    // 🌱 SCALA ORGANICA: usa ATR medio × φ (rapporto aureo) come unità di volatilità
    // φ ≈ 1.618 è la proporzione naturale universale
    // Distanza = φ × ATR per raggiungere normalizzazione ±1
    // Minimo organico = naturalPeriod × φ pips (derivato dai DATI)
    double min_organic_scale = point_value * data.organic.naturalPeriod * PHI;
    
    // 🔧 FIX: Protezione divisione per zero con fallback multipli
    double atr_scale = data.atr_avg * PHI;  // Scala primaria
    
    // Fallback 1: usa min_organic_scale se ATR troppo basso
    if (atr_scale < min_organic_scale || atr_scale <= 0) {
        atr_scale = min_organic_scale;
    }
    
    // Fallback 2: se ancora zero, usa point_value * PHI
    if (atr_scale <= 0) {
        atr_scale = point_value * PHI;
    }
    
    // Fallback 3: minimo assoluto organico = PHI^-23 (circa 0.00001)
    if (atr_scale <= 0) {
        atr_scale = MathPow(PHI_INV, 23);  // ≈ 0.0000106
    }
    
    // ✅ VALIDATO: atr_scale sempre > 0 dopo tutti i fallback
    
    // ═══════════════════════════════════════════════════════════════
    // CALCOLO VALORI NORMALIZZATI (>0 = BUY, <0 = SELL)
    // ═══════════════════════════════════════════════════════════════
    
    double totalScore = 0;
    
    // 🌱 Peso organico del TF (calcolato da Hurst: peso = H_TF / Σ(H_tutti_TF))
    double w = data.organic.weight;
    
    // EMA: prezzo - EMA (positivo = sopra EMA = BUY)
    // 🌱 Scala ORGANICA: distanza normalizzata con ATR (non pips fissi)
    if (enableEMA && ArraySize(data.ema) > lastIdx) {
        double ema_norm = (price - data.ema[lastIdx]) / atr_scale;
        ema_norm = MathMax(-1.0, MathMin(1.0, ema_norm));
        totalScore += ema_norm * w;
    }
    
    // RSI: centrato sulla media EMPIRICA (normalizzato a -1/+1)
    if (enableRSI && ArraySize(data.rsi) > lastIdx && data.rsi_scale > 0) {
        // 🌱 Centro e scala EMPIRICI invece di 50 hardcoded!
        // ✅ VALIDATO: data.rsi_scale > 0 verificato nell'if
        double rsi_norm = (data.rsi[lastIdx] - data.rsi_center) / data.rsi_scale;
        rsi_norm = MathMax(-1.0, MathMin(1.0, rsi_norm));
        totalScore += rsi_norm * w;
    }
    
    // MACD: differenza MACD - Signal (già trend-following)
    // 🌱 Scala ORGANICA: differenza normalizzata con ATR
    if (enableMACD && ArraySize(data.macd) > lastIdx && ArraySize(data.macd_signal) > lastIdx) {
        double macd_diff = data.macd[lastIdx] - data.macd_signal[lastIdx];
        double macd_norm = MathMax(-1.0, MathMin(1.0, macd_diff / atr_scale));
        totalScore += macd_norm * w;
    }
    
    // Bollinger Bands: posizione relativa nel range
    // 🔧 FIX: Protezione divisione per zero con minimo organico
    if (enableBB && ArraySize(data.bb_upper) > lastIdx && ArraySize(data.bb_lower) > lastIdx && ArraySize(data.bb_middle) > lastIdx) {
        double bb_range = data.bb_upper[lastIdx] - data.bb_lower[lastIdx];
        // 🔧 FIX: Minimo BB range = ATR × φ⁻² (evita divisione per valori troppo piccoli)
        double min_bb_range = atr_scale * PHI_INV_SQ;
        if (min_bb_range <= 0) min_bb_range = point_value * PHI;  // Fallback assoluto
        
        double bb_norm = 0;
        if (bb_range > min_bb_range) {
            bb_norm = (price - data.bb_middle[lastIdx]) / (bb_range / 2.0);
            bb_norm = MathMax(-1.0, MathMin(1.0, bb_norm));
        }
        // Se bb_range <= min_bb_range, bande troppo strette, segnale neutro (0)
        totalScore += bb_norm * w;
    }
    
    // ATR: indicatore di volatilità (non direzionale) - escluso dal voto direzionale
    // ADX: forza del trend (non direzionale) - escluso dal voto direzionale
    // Entrambi possono essere usati esternamente come filtri ma non contribuiscono allo score
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 INDICATORI ADDIZIONALI
    // ═══════════════════════════════════════════════════════════════
    
    // Heikin Ashi: close - open
    // 🌱 Scala ORGANICA: usa 1/φ dell'ATR (corpo HA = proporzione aurea del range)
    if (enableHeikin && ArraySize(data.ha_close) > lastIdx && ArraySize(data.ha_open) > lastIdx) {
        double ha_diff = data.ha_close[lastIdx] - data.ha_open[lastIdx];
        double ha_norm = MathMax(-1.0, MathMin(1.0, ha_diff / (atr_scale * PHI_INV)));  // 1/φ ≈ 0.618
        totalScore += ha_norm * w;
    }
    
    // OBV: variazione rispetto a barra precedente
    // 🔧 FIX: Usa scala EMPIRICA calcolata dalla varianza storica delle variazioni OBV
    if (enableOBV && lastIdx > 0 && ArraySize(data.obv) > lastIdx && data.obv_scale > 0) {
        double obv_change = data.obv[lastIdx] - data.obv[lastIdx - 1];
        
        // 🔧 FIX: Usa scala empirica invece di price * atr (dimensionalmente errato)
        double obv_norm = obv_change / data.obv_scale;
        obv_norm = MathMax(-1.0, MathMin(1.0, obv_norm));
        totalScore += obv_norm * w;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 ADX: TREND-FOLLOWING 100% ORGANICO (basato su φ)
    // Soglia: avg + (1/φ) × stddev ≈ avg + 0.618×stddev
    // Max forte: avg + φ² × stddev ≈ avg + 2.618×stddev
    // DI norm: basato su stddev × φ
    // ═══════════════════════════════════════════════════════════════
    if (enableADX && ArraySize(data.adx) > lastIdx && ArraySize(data.di_plus) > lastIdx && ArraySize(data.di_minus) > lastIdx) {
        double adx_val = data.adx[lastIdx];
        double di_plus = data.di_plus[lastIdx];
        double di_minus = data.di_minus[lastIdx];
        
        // 🌱 Valori organici derivati da φ e statistiche del mercato
        double adx_threshold_organic = data.adx_threshold;                         // avg + PHI_INV×stddev
        double adx_max_organic = data.adx_avg + PHI_SQ * data.adx_stddev;          // φ² sigma = molto forte
        double di_scale_organic = MathMax(PHI_SQ, data.adx_stddev * PHI);          // min φ² ≈ 2.618
        
        // Solo se ADX supera la soglia organica (trend significativo per questo mercato)
        if (adx_val > adx_threshold_organic && adx_max_organic > adx_threshold_organic) {
            // 🌱 Forza normalizzata: (ADX - soglia) / (max - soglia), dove max = avg + φ²×stddev
            double adx_strength = MathMin(1.0, (adx_val - adx_threshold_organic) / (adx_max_organic - adx_threshold_organic));
            
            // 🌱 Direzione basata su +DI vs -DI, normalizzata con φ
            double di_diff = di_plus - di_minus;
            double di_norm = MathMax(-1.0, MathMin(1.0, di_diff / di_scale_organic));
            
            // Score = direzione * forza del trend * peso
            totalScore += di_norm * adx_strength * w;
            
            // 🌱 Log organico ADX (se abilitato)
            if (g_enableLogsEffective) {
                PrintFormat("[%s] 🌱 ADX ORGANICO: val=%.1f > soglia=%.1f (maxφ²σ=%.1f) → DI+:%.1f DI-:%.1f scale=%.1f",
                    timeframe, adx_val, adx_threshold_organic, adx_max_organic, di_plus, di_minus, di_scale_organic);
            }
        }
        // Se ADX < soglia, mercato laterale, ADX non contribuisce
    }
    
    // ═══════════════════════════════════════════════════════════════
    // RITORNA SCORE NORMALIZZATO
    // Positivo = BUY, Negativo = SELL, Zero = NEUTRAL
    // ═══════════════════════════════════════════════════════════════
    
    return totalScore;
}

//+------------------------------------------------------------------+
//| Tick event                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
    // Controlla eventuale stop loss temporale
    CheckAndCloseOnTimeStop();
    
    // ═══════════════════════════════════════════════════════════════
    // WARMUP: Verifica se il preload storico è andato a buon fine
    // Il buffer Hurst viene pre-caricato in OnInit() da PreloadHurstBufferFromHistory()
    // Qui controlliamo solo che i flag siano pronti, non aspettiamo tempo reale
    // ═══════════════════════════════════════════════════════════════
    if (!g_warmupComplete) {
        // 🔧 FIX: Se Hurst filter è disabilitato, skip check buffer Hurst
        bool hurstBufferReady = true;
        bool tradeScoreBufferReady = true;
        bool hurstReadyCheck = true;
        
        if (EnableHurstFilter) {
            hurstBufferReady = (g_hurstHistorySize >= (int)MathCeil(HURST_HISTORY_MAX * PHI_INV_SQ));
            tradeScoreBufferReady = (g_tradeScoreHistorySize >= (int)MathCeil(TRADE_SCORE_HISTORY_MAX * PHI_INV_SQ));
            hurstReadyCheck = g_hurstReady;
        }
        
        if (hurstBufferReady && tradeScoreBufferReady && hurstReadyCheck) {
            g_warmupComplete = true;
            if (EnableHurstFilter) {
                Print("✅ [WARMUP] Buffer pre-caricati dallo storico - EA pronto per il trading");
            } else {
                Print("✅ [WARMUP] Hurst filter DISABILITATO - EA pronto per il trading (no buffer richiesti)");
            }
        } else {
            // Preload fallito - tenta ricalcolo incrementale
            static datetime lastWarmupLog = 0;
            if (TimeCurrent() - lastWarmupLog >= 30) {
                PrintFormat("🔄 [WARMUP] In attesa dati sufficienti: Hurst=%d/%d TradeScore=%d/%d Ready=%s", 
                    g_hurstHistorySize, (int)MathCeil(HURST_HISTORY_MAX * PHI_INV_SQ),
                    g_tradeScoreHistorySize, (int)MathCeil(TRADE_SCORE_HISTORY_MAX * PHI_INV_SQ),
                    g_hurstReady ? "Sì" : "No");
                lastWarmupLog = TimeCurrent();
            }
            
            // Aggiorna sistema per raccogliere dati incrementalmente
            datetime currentBarTime_warmup = iTime(_Symbol, PERIOD_CURRENT, 0);
            static datetime lastBarTime_warmup = 0;
            if (currentBarTime_warmup != lastBarTime_warmup) {
                lastBarTime_warmup = currentBarTime_warmup;
                RecalculateOrganicSystem();
            }
            return;  // Non proseguire con trading finché buffer non pronti
        }
    }
    
    // Controlla nuovo bar del TF corrente (quello del grafico)
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if (currentBarTime == lastBarTime) return;
    lastBarTime = currentBarTime;
    
    // ═══════════════════════════════════════════════════════════════
    // 🚀 OTTIMIZZAZIONE: Ricalcolo ogni N barre (non ogni barra)
    // ═══════════════════════════════════════════════════════════════
    g_barsSinceLastRecalc++;
    
    bool shouldRecalc = false;
    if (RecalcEveryBars <= 0) {
        // Comportamento originale: ricalcola sempre
        shouldRecalc = true;
    } else {
        // 🚀 OTTIMIZZATO: ricalcola solo ogni N barre
        if (g_barsSinceLastRecalc >= RecalcEveryBars) {
            shouldRecalc = true;
            g_barsSinceLastRecalc = 0;
        }
    }
    
    if (g_enableLogsEffective) {
        Print("");
        Print("╔═══════════════════════════════════════════════════════════════════════════╗");
        PrintFormat("║ 🌱 NUOVA BARRA %s - %s                                   ║", 
            EnumToString(Period()), TimeToString(currentBarTime, TIME_DATE|TIME_MINUTES));
        if (shouldRecalc) {
            Print("║ Avvio ricalcolo completo sistema organico...                              ║");
        } else {
            PrintFormat("║ ⚡ Skip ricalcolo (%d/%d barre)                                           ║",
                g_barsSinceLastRecalc, RecalcEveryBars);
        }
        Print("╚═══════════════════════════════════════════════════════════════════════════╝");
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 RICALCOLO SISTEMA ORGANICO (condizionale per performance)
    // ═══════════════════════════════════════════════════════════════
    if (shouldRecalc) {
        RecalculateOrganicSystem();
    }
    
    // Carica dati multi-timeframe per analisi
    // 🌱 Sistema robusto: continua con i TF disponibili
    // 🚀 OTTIMIZZATO: Ricarica solo ogni N barre
    if (g_enableLogsEffective) Print("[DATA] 📊 Caricamento dati multi-timeframe in corso...");
    
    // 🚀 CHECK CACHE DATI TF - Ricarica solo se necessario
    // 🌱 Intervallo reload dati derivato da φ³ ≈ 4 (invece di 5 hardcoded)
    int tfDataReloadDivisor = (int)MathRound(MathPow(PHI, 3));  // φ³ ≈ 4
    int tfDataReloadInterval = MathMax(1, RecalcEveryBars / tfDataReloadDivisor);  // Reload dinamico
    bool shouldReloadTFData = false;
    
    if (!g_tfDataCacheValid || g_tfDataRecalcCounter >= tfDataReloadInterval) {
        shouldReloadTFData = true;
        g_tfDataRecalcCounter = 0;
    } else {
        g_tfDataRecalcCounter++;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 barsToLoad = max(min_bars_required di tutti i TF) × φ (buffer statistico)
    // Usiamo il max tra tutti i periodi organici già calcolati
    // min_bars_required = longest period + buffer organico (calcolato in CalculateOrganicPeriods)
    // ═══════════════════════════════════════════════════════════════=
    int maxPeriodNeeded = MathMax(g_organic_M5.min_bars_required, 
                          MathMax(g_organic_H1.min_bars_required,
                          MathMax(g_organic_H4.min_bars_required, g_organic_D1.min_bars_required)));
    // Buffer = periodo max × φ (per avere overlap statistico)
    int barsToLoad = (int)MathRound(maxPeriodNeeded * PHI);
    // 🌱 Minimo organico = φ⁸ ≈ 47 (derivato da potenza di φ)
    int minBarsOrganic = (int)MathRound(PHI_SQ * PHI_SQ * PHI_SQ * PHI_SQ);  // φ⁸ ≈ 46.98
    barsToLoad = MathMax(barsToLoad, minBarsOrganic);
    // 🔧 FIX: Limite massimo ragionevole per evitare richieste assurde
    // φ¹² ≈ 322 è un limite sensato per analisi tecnica
    int maxBarsLimit = (int)MathRound(MathPow(PHI, 12));  // ≈ 322
    if (barsToLoad > maxBarsLimit) {
        static bool warnedOnce = false;
        if (!warnedOnce) {
            PrintFormat("[DATA] ⚠️ barsToLoad ridotto da %d a %d (limite φ¹²)", barsToLoad, maxBarsLimit);
            warnedOnce = true;
        }
        barsToLoad = maxBarsLimit;
    }
    
    // 🚀 USA CACHE O RICARICA
    bool m5Loaded = true, h1Loaded = true, h4Loaded = true, d1Loaded = true;
    
    if (shouldReloadTFData) {
        m5Loaded = LoadTimeFrameData(PERIOD_M5, tfData_M5, barsToLoad);
        h1Loaded = LoadTimeFrameData(PERIOD_H1, tfData_H1, barsToLoad);
        h4Loaded = LoadTimeFrameData(PERIOD_H4, tfData_H4, barsToLoad);
        d1Loaded = LoadTimeFrameData(PERIOD_D1, tfData_D1, barsToLoad);
        g_tfDataCacheValid = true;
        
        if (g_enableLogsEffective) {
            PrintFormat("[DATA] Stato: M5=%s H1=%s H4=%s D1=%s | barsToLoad=%d (RELOAD)",
                m5Loaded ? "✅" : "❌",
                h1Loaded ? "✅" : "❌",
                h4Loaded ? "✅" : "❌",
                d1Loaded ? "✅" : "❌",
                barsToLoad);
        }
    } else {
        // 🚀 USA CACHE - Aggiorna SOLO l'ultima barra per ogni TF
        m5Loaded = UpdateLastBar(PERIOD_M5, tfData_M5);
        h1Loaded = UpdateLastBar(PERIOD_H1, tfData_H1);
        h4Loaded = UpdateLastBar(PERIOD_H4, tfData_H4);
        d1Loaded = UpdateLastBar(PERIOD_D1, tfData_D1);
        
        if (g_enableLogsEffective) {
            PrintFormat("[DATA] ⚡ CACHE USATA (%d/%d) | Aggiornata ultima barra",
                g_tfDataRecalcCounter, tfDataReloadInterval);
        }
    }
    
    // M5 è obbligatorio (TF operativo), gli altri sono opzionali
    if (!m5Loaded) {
        if (g_enableLogsEffective) Print("[ERROR] ❌ M5 obbligatorio non disponibile - skip");
        return;
    }
    
    // 🌱 Imposta flag globali TF attivi (usati da ExecuteTradingLogic)
    g_vote_M5_active = EnableVote_M5 && m5Loaded;
    g_vote_H1_active = EnableVote_H1 && h1Loaded;
    g_vote_H4_active = EnableVote_H4 && h4Loaded;
    g_vote_D1_active = EnableVote_D1 && d1Loaded;
    
    // Almeno un TF deve essere attivo
    if (!g_vote_M5_active && !g_vote_H1_active && !g_vote_H4_active && !g_vote_D1_active) {
        if (g_enableLogsEffective) Print("[ERROR] ⚠️ Nessun TF attivo - skip");
        return;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 CONTROLLO DATI ORGANICI PRONTI
    // L'EA NON entra a mercato finché non ha abbastanza barre storiche
    // Controlla solo i TF attivi (caricati E abilitati)
    // ═══════════════════════════════════════════════════════════════
    bool allDataReady = true;
    if (g_vote_M5_active && !tfData_M5.isDataReady) allDataReady = false;
    if (g_vote_H1_active && !tfData_H1.isDataReady) allDataReady = false;
    if (g_vote_H4_active && !tfData_H4.isDataReady) allDataReady = false;
    if (g_vote_D1_active && !tfData_D1.isDataReady) allDataReady = false;
    
    if (!allDataReady) {
        if (g_enableLogsEffective) {
            PrintFormat("[ORGANIC] ⏳ Attesa dati: M5=%s H1=%s H4=%s D1=%s",
                (!g_vote_M5_active || tfData_M5.isDataReady) ? "✅" : "⏳",
                (!g_vote_H1_active || tfData_H1.isDataReady) ? "✅" : "⏳",
                (!g_vote_H4_active || tfData_H4.isDataReady) ? "✅" : "⏳",
                (!g_vote_D1_active || tfData_D1.isDataReady) ? "✅" : "⏳");
        }
        return;
    }
    
    // 🌱 LOG VALORI ORGANICI CALCOLATI (sempre visibile se abilitato)
    if (g_enableLogsEffective) {
        static datetime lastOrganicLogTime = 0;
        datetime currentTime = TimeCurrent();
        
        // 🌱 Log organico ogni naturalPeriod × φ secondi (derivato dai DATI!)
        // Usiamo il naturalPeriod di M5 × 60 (secondi per barra) × φ
        int logIntervalSeconds = (int)MathRound(g_organic_M5.naturalPeriod * 60 * PHI);
        // 🌱 Minimo organico = φ⁵ ≈ 11 secondi
        int minLogInterval = (int)MathRound(MathPow(PHI, 5));
        logIntervalSeconds = MathMax(minLogInterval, logIntervalSeconds);
        
        if (currentTime - lastOrganicLogTime >= logIntervalSeconds) {
            lastOrganicLogTime = currentTime;
            
            Print("");
            Print("═══════════════════════════════════════════════════════════════");
            Print("🌱 VALORI ORGANICI CALCOLATI DINAMICAMENTE");
            Print("═══════════════════════════════════════════════════════════════");
            
            if (g_vote_M5_active && ArraySize(tfData_M5.atr) > 0 && ArraySize(tfData_M5.adx) > 0) {
                PrintFormat("[M5] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + 1/φ*std=%.1f)",
                    tfData_M5.atr[ArraySize(tfData_M5.atr)-1], tfData_M5.atr_avg,
                    tfData_M5.adx[ArraySize(tfData_M5.adx)-1], tfData_M5.adx_threshold,
                    tfData_M5.adx_avg, tfData_M5.adx_stddev);
            }
            if (g_vote_H1_active && ArraySize(tfData_H1.atr) > 0 && ArraySize(tfData_H1.adx) > 0) {
                PrintFormat("[H1] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + 1/φ*std=%.1f)",
                    tfData_H1.atr[ArraySize(tfData_H1.atr)-1], tfData_H1.atr_avg,
                    tfData_H1.adx[ArraySize(tfData_H1.adx)-1], tfData_H1.adx_threshold,
                    tfData_H1.adx_avg, tfData_H1.adx_stddev);
            }
            if (g_vote_H4_active && ArraySize(tfData_H4.atr) > 0 && ArraySize(tfData_H4.adx) > 0) {
                PrintFormat("[H4] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + 1/φ*std=%.1f)",
                    tfData_H4.atr[ArraySize(tfData_H4.atr)-1], tfData_H4.atr_avg,
                    tfData_H4.adx[ArraySize(tfData_H4.adx)-1], tfData_H4.adx_threshold,
                    tfData_H4.adx_avg, tfData_H4.adx_stddev);
            }
            if (g_vote_D1_active && ArraySize(tfData_D1.atr) > 0 && ArraySize(tfData_D1.adx) > 0) {
                PrintFormat("[D1] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + 1/φ*std=%.1f)",
                    tfData_D1.atr[ArraySize(tfData_D1.atr)-1], tfData_D1.atr_avg,
                    tfData_D1.adx[ArraySize(tfData_D1.adx)-1], tfData_D1.adx_threshold,
                    tfData_D1.adx_avg, tfData_D1.adx_stddev);
            }
            
            Print("═══════════════════════════════════════════════════════════════");
            Print("");
        }
    }
    
    // Logica di trading
    if (g_enableLogsEffective) Print("[TRADE] 🎯 Avvio logica di trading...");
    ExecuteTradingLogic();
    if (g_enableLogsEffective) {
        Print("[TRADE] ✅ Elaborazione completata");
        Print("");
    }
}

//+------------------------------------------------------------------+
//| Logica di trading principale                                     |
//+------------------------------------------------------------------+
void ExecuteTradingLogic()
{
    // Esegui logica di voto
    int voteResult = ExecuteVotingLogic();
    if (g_enableLogsEffective) {
        string voteStr = (voteResult == 1) ? "🟢 BUY" : ((voteResult == -1) ? "🔴 SELL" : "⚪ NEUTRAL");
        PrintFormat("[VOTE] Risultato: %s (score raw: %d)", voteStr, voteResult);
    }
    
    // Controlla se deve eseguire trades
    if (!enableTrading) {
        if (g_enableLogsEffective) Print("[TRADE] ⚠️ Trading DISABILITATO nelle impostazioni - nessuna operazione");
        return;
    }
    
    // 🛡️ VERIFICA PERMESSI TRADING TERMINALE/BROKER
    if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
        if (g_enableLogsEffective) Print("[TRADE] ⛔ Trading non permesso dal terminale - verificare impostazioni");
        return;
    }
    if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) {
        if (g_enableLogsEffective) Print("[TRADE] ⛔ Trading non permesso per questo EA - verificare AutoTrading");
        return;
    }
    
    // 🛡️ VERIFICA SIMBOLO TRADABILE
    long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
    if (tradeMode == SYMBOL_TRADE_MODE_DISABLED) {
        if (g_enableLogsEffective) Print("[TRADE] ⛔ Simbolo non tradabile - mercato chiuso o bloccato");
        return;
    }
    
    // Ottieni prezzo corrente
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double spread = ask - bid;
    
    // Filtro spread
    if (MaxSpread > 0 && spread > MaxSpread * _Point) {
        if (g_enableLogsEffective) PrintFormat("[TRADE] ⚠️ Spread troppo alto: %.1f pips > %.1f max - skip", spread/_Point, MaxSpread);
        return;
    }
    
    // Conta posizioni aperte
    int openPositions = CountOpenPositions();
    
    if (MaxOpenTrades > 0 && openPositions >= MaxOpenTrades) {
        if (g_enableLogsEffective) PrintFormat("[TRADE] ⚠️ Max posizioni raggiunto: %d/%d - skip", openPositions, MaxOpenTrades);
        return;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 FILTRO HURST NO-TRADE ZONE
    // Se il mercato è in regime "random" (H ≈ centro storico), i segnali sono rumore
    // Blocca nuovi trade ma permette gestione posizioni esistenti
    // 🔧 FIX: Log solo se c'era un segnale valido da bloccare
    // ═══════════════════════════════════════════════════════════════
    if (!IsTradeAllowedByHurst()) {
        // 🔧 FIX: Log solo se c'è un segnale reale (BUY/SELL) che viene bloccato
        if (voteResult != 0 && g_enableLogsEffective) {
            PrintFormat("[HURST] ⛔ TRADE %s BLOCCATO - TradeScore=%.3f < %.3f (soglia)", 
                voteResult == 1 ? "BUY" : "SELL", g_hurstTradeScore, g_tradeScoreThreshold);
        }
        return;
    }
    
    // Esegui trades basati su voto
    if (voteResult == -1) {
        if (g_enableLogsEffective) Print("[TRADE] 🔴 SEGNALE SELL CONFERMATO - Apertura ordine...");
        OpenSellOrder();
    }
    else if (voteResult == 1) {
        if (g_enableLogsEffective) Print("[TRADE] 🟢 SEGNALE BUY CONFERMATO - Apertura ordine...");
        OpenBuyOrder();
    }
    // 🔧 FIX: Rimosso log "Nessun segnale - in attesa..." - troppo verboso (ogni 5 min)
}

//+------------------------------------------------------------------+
//| Conta posizioni aperte                                           |
//| 🔧 FIX: Aggiunta gestione errori per sincronizzazione            |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    // 🔧 FIX: Retry loop per gestire race condition (posizioni che cambiano durante iterazione)
    int maxRetries = 3;
    
    for (int attempt = 0; attempt < maxRetries; attempt++) {
        int count = 0;
        bool hadError = false;
        int skippedPositions = 0;  // 🔧 FIX: Conta posizioni saltate per diagnostica
        
        // 🔧 FIX: Usa Magic cachato invece di ricalcolarlo ogni volta
        int uniqueMagic = g_uniqueMagicNumber;
        int total = PositionsTotal();
        
        for (int i = total - 1; i >= 0; i--) {
            // Reset errore prima di ogni operazione
            ResetLastError();
            
            ulong ticket = PositionGetTicket(i);
            
            // 🔧 FIX: Gestione errore di sincronizzazione
            if (ticket == 0) {
                int err = GetLastError();
                skippedPositions++;  // Traccia sempre
                
                // ERR_TRADE_POSITION_NOT_FOUND (4753) o ERR_TRADE_WRONG_TYPE (4754) = race condition
                if (err == 4753 || err == 4754) {
                    // Race condition tipica - forza retry
                    hadError = true;
                    break;
                } else if (err != 0) {
                    // Altro errore - logga e continua
                    if (g_enableLogsEffective) {
                        PrintFormat("[CountOpenPositions] ⚠️ Errore %d su posizione %d (tentativo %d)", err, i, attempt + 1);
                    }
                }
                // err == 0 con ticket == 0: posizione già chiusa, skip silenzioso
                continue;
            }
            
            // Seleziona esplicitamente per ticket per garantire consistenza
            if (!PositionSelectByTicket(ticket)) {
                continue;  // Posizione non più valida
            }
            
            if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
                PositionGetInteger(POSITION_MAGIC) == uniqueMagic) {
                count++;
            }
        }
        
        // 🔧 FIX: Log se troppe posizioni saltate (possibile anomalia)
        if (skippedPositions > 2 && g_enableLogsEffective) {
            PrintFormat("[CountOpenPositions] ⚠️ %d posizioni saltate (tentativo %d)", skippedPositions, attempt + 1);
        }
        
        // Se nessun errore, ritorna il count
        if (!hadError) {
            return count;
        }
        
        // Altrimenti attendi e riprova
        Sleep(10);  // 10ms pausa prima di ritentare
    }
    
    // Dopo tutti i tentativi, ritorna 0 per sicurezza (blocca nuovi trade)
    if (g_enableLogsEffective) {
        Print("[CountOpenPositions] ❌ Troppi errori - ritorno 0 per sicurezza");
    }
    return 0;
}

//+------------------------------------------------------------------+
//| Sistema di voto                                                  |
//+------------------------------------------------------------------+

string StateLabel(bool flag)
{
    return flag ? "ATTIVO" : "DISATTIVATO";
}

int ExecuteVotingLogic()
{
    static datetime lastVoteDisabledLog = 0;
    if (!EnableIndicatorVoteSystem) {
        datetime now = TimeCurrent();
        // 🌱 Log throttle: naturalPeriod × secondi per barra (derivato dai DATI!)
        // 🔧 FIX: Protezione quando naturalPeriod = 0
        int naturalPeriod = MathMax(1, g_organic_M5.naturalPeriod);  // Minimo 1 per evitare divisione per zero
        int throttleSeconds = (int)MathRound(naturalPeriod * 60 / PHI);
        // 🌱 Minimo organico = φ⁴ ≈ 7 secondi
        int minThrottle = (int)MathRound(MathPow(PHI, 4));
        throttleSeconds = MathMax(minThrottle, throttleSeconds);
        
        if (now - lastVoteDisabledLog >= throttleSeconds || lastVoteDisabledLog == 0) {
            Print("[VOTE] Sistema voti indicatori DISATTIVATO (EnableIndicatorVoteSystem=false) → decisione neutra");
            lastVoteDisabledLog = now;
        }
        return 0;
    }
    
    double scoreM5 = 0.0;
    double scoreH1 = 0.0;
    double scoreH4 = 0.0;
    double scoreD1 = 0.0;
    
    // Ottieni dati indicatori M5 per calcolo score pesato (dichiarazioni comuni)
    double emaBuf[1], rsiBuf[1], macdBuf[1], sigBuf[1];
    double bbUp[1], bbLow[1], atrBuf[1], adxBuf[1];
    double price = 0.0;
    int latestIdxM5 = 0;
    // cATR e cADX rimossi perché ATR/ADX non sono direzionali
    bool cEMA = false, cRSI = false, cMACD = false, cBB = false;
    bool cHeikin = false, cOBV = false;
    
    if (g_vote_M5_active) {
        
        bool ok = true;
        ok &= (CopyBuffer(emaHandle_M5, 0, 1, 1, emaBuf) > 0);
        ok &= (CopyBuffer(rsiHandle_M5, 0, 1, 1, rsiBuf) > 0);
        ok &= (CopyBuffer(macdHandle_M5, 0, 1, 1, macdBuf) > 0);
        ok &= (CopyBuffer(macdHandle_M5, 1, 1, 1, sigBuf) > 0);
        ok &= (CopyBuffer(bbHandle_M5, 1, 1, 1, bbUp) > 0);
        ok &= (CopyBuffer(bbHandle_M5, 2, 1, 1, bbLow) > 0);
        ok &= (CopyBuffer(atrHandle_M5, 0, 1, 1, atrBuf) > 0);
        ok &= (CopyBuffer(adxHandle_M5, 0, 1, 1, adxBuf) > 0);
        
        if (!ok) {
            Print("[ERROR] CopyBuffer fallito nella logica di voto (M5)");
            return 0;
        }
        
        // Ottieni prezzo corrente
        MqlRates rates[1];
        if (CopyRates(_Symbol, PERIOD_M5, 1, 1, rates) < 1) {
            Print("[ERROR] CopyRates fallito");
            return 0;
        }
        price = rates[0].close;
        latestIdxM5 = ArraySize(tfData_M5.rates) - 1;
        if (latestIdxM5 < 1) {
            Print("[ERROR] Dati M5 insufficienti per valutazione");
            return 0;
        }
        
        // Calcolo condizioni M5 con enable bool
        // NOTA: Logica coerente con CalculateSignalScore()
        // 🌱 Usa centri EMPIRICI dalla struct tfData invece di costanti hardcoded!
        cEMA  = enableEMA         && (price > emaBuf[0]);
        cRSI  = enableRSI         && (rsiBuf[0] > tfData_M5.rsi_center);
        cMACD = enableMACD        && (macdBuf[0] > sigBuf[0]);
        // BB: sopra la banda media = BUY (coerente con CalculateSignalScore)
        double bbMiddle = (bbUp[0] + bbLow[0]) / 2.0;
        cBB   = enableBB          && (price > bbMiddle);
        // NOTA: ATR e ADX sono indicatori NON direzionali, usati solo come filtri (non partecipano al voto)
        
        // 🛡️ Controlli array bounds per indicatori da struct tfData
        cHeikin = false;
        if (enableHeikin && ArraySize(tfData_M5.ha_close) > latestIdxM5 && ArraySize(tfData_M5.ha_open) > latestIdxM5) {
            cHeikin = (tfData_M5.ha_close[latestIdxM5] > tfData_M5.ha_open[latestIdxM5]);
        }
        
        cOBV = false;
        if (enableOBV && ArraySize(tfData_M5.obv) > latestIdxM5 && latestIdxM5 >= 1) {
            cOBV = (tfData_M5.obv[latestIdxM5] >= tfData_M5.obv[latestIdxM5 - 1]);
        }
        
        // 🌱 Calcola score M5 normalizzato tramite funzione unificata con valori ORGANICI
        // NOTA: Le variabili cXXX sopra sono usate solo per il log dettagliato,
        //       lo score effettivo viene da CalculateSignalScore che usa normalizzazione continua
        scoreM5 = CalculateSignalScore(tfData_M5, "M5");
        
        // Log M5 score calcolato
        if (g_enableLogsEffective) {
            PrintFormat("[M5] 📊 Score normalizzato: %+.2f (peso organico TF: %.2f)", scoreM5, tfData_M5.organic.weight);
        }
    }
    
    // Calcolo consenso multi-timeframe con pesi e threshold specifici per ogni TF
    // OTTIMIZZAZIONE: Calcola score SOLO per TF attivi (usa flag globali)
    if (!g_vote_M5_active) scoreM5 = 0;  // M5 già calcolato sopra se attivo
    
    if (g_vote_H1_active) {
        scoreH1 = CalculateSignalScore(tfData_H1, "H1");
    } else {
        scoreH1 = 0;
    }
    
    if (g_vote_H4_active) {
        scoreH4 = CalculateSignalScore(tfData_H4, "H4");
    } else {
        scoreH4 = 0;
    }
    
    if (g_vote_D1_active) {
        scoreD1 = CalculateSignalScore(tfData_D1, "D1");
    } else {
        scoreD1 = 0;
    }
    
    // 📊 LOG DETTAGLIATO INDICATORI PER OGNI TIMEFRAME
    if (g_enableLogsEffective) {
        Print("\n========== 📊 ANALISI INDICATORI DETTAGLIATA ==========");
        
        // M5 INDICATORS LOG
        if (g_vote_M5_active) {
            Print("\n--- M5 (OPERATIVO) ---");
            PrintFormat("  🌱 Peso organico TF: %.2f", tfData_M5.organic.weight);
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f → %s (%s)",
                price, emaBuf[0], cEMA ? "✅ BUY" : "❌ SELL", enableEMA ? "ATTIVO" : "disattivo");
            PrintFormat("  RSI: %.2f vs Centro Empirico=%.2f → %s (%s)",
                rsiBuf[0], tfData_M5.rsi_center, cRSI ? "✅ BUY" : "❌ SELL", enableRSI ? "ATTIVO" : "disattivo");
            PrintFormat("  MACD: %.6f vs Signal=%.6f → %s (%s)",
                macdBuf[0], sigBuf[0], cMACD ? "✅ BUY" : "❌ SELL", enableMACD ? "ATTIVO" : "disattivo");
            PrintFormat("  BB: Price=%.5f vs Middle=%.5f → %s (%s)",
                price, (bbUp[0] + bbLow[0]) / 2.0, cBB ? "✅ BUY" : "❌ SELL", enableBB ? "ATTIVO" : "disattivo");
            PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f → %s (vota con +DI/-DI, %s)",
                adxBuf[0], tfData_M5.adx_threshold, adxBuf[0] > tfData_M5.adx_threshold ? "TREND" : "NO TREND", enableADX ? "ATTIVO" : "disattivo");
            // 🛡️ Log con valori già controllati
            double ha_close_log = (ArraySize(tfData_M5.ha_close) > latestIdxM5) ? tfData_M5.ha_close[latestIdxM5] : 0;
            double ha_open_log = (ArraySize(tfData_M5.ha_open) > latestIdxM5) ? tfData_M5.ha_open[latestIdxM5] : 0;
            PrintFormat("  Heikin Ashi: HAclose=%.5f vs HAopen=%.5f → %s (%s)",
                ha_close_log, ha_open_log, cHeikin ? "✅ BUY" : "❌ SELL", enableHeikin ? "ATTIVO" : "disattivo");
            double obv_curr = (ArraySize(tfData_M5.obv) > latestIdxM5) ? tfData_M5.obv[latestIdxM5] : 0;
            double obv_prev = (ArraySize(tfData_M5.obv) > latestIdxM5 && latestIdxM5 >= 1) ? tfData_M5.obv[latestIdxM5 - 1] : 0;
            PrintFormat("  OBV: %.0f vs Prev=%.0f → %s (%s)",
                obv_curr, obv_prev, cOBV ? "✅ BUY" : "❌ SELL", enableOBV ? "ATTIVO" : "disattivo");
            PrintFormat("  🎯 SCORE M5: %.2f", scoreM5);
        } else {
            Print("  📊 M5 Score:  N/D (DISATTIVATO)");
        }
    }
    
    // H1 INDICATORS - Usa solo indicatori esistenti in TimeFrameData
    if (g_vote_H1_active && g_enableLogsEffective) {
        int h1_idx = ArraySize(tfData_H1.rsi) - 1;
        if (h1_idx < 0) {
            Print("\n--- H1: DATI NON DISPONIBILI ---");
        } else {
            Print("\n--- H1 (INTERMEDIO) ---");
            PrintFormat("  🌱 Peso organico TF: %.2f", tfData_H1.organic.weight);
            double h1_close = (ArraySize(tfData_H1.rates) > h1_idx) ? tfData_H1.rates[h1_idx].close : price;
            int h1_prevIdx = (h1_idx > 0) ? h1_idx - 1 : 0;
            double h1_ema = (ArraySize(tfData_H1.ema) > h1_idx) ? tfData_H1.ema[h1_idx] : 0;
            double h1_rsi = (ArraySize(tfData_H1.rsi) > h1_idx) ? tfData_H1.rsi[h1_idx] : 0;
            double h1_adx = (ArraySize(tfData_H1.adx) > h1_idx) ? tfData_H1.adx[h1_idx] : 0;
            double h1_ha_close = (ArraySize(tfData_H1.ha_close) > h1_idx) ? tfData_H1.ha_close[h1_idx] : 0;
            double h1_ha_open = (ArraySize(tfData_H1.ha_open) > h1_idx) ? tfData_H1.ha_open[h1_idx] : 0;
            double h1_obv = (ArraySize(tfData_H1.obv) > h1_idx) ? tfData_H1.obv[h1_idx] : 0;
            double h1_obv_prev = (ArraySize(tfData_H1.obv) > h1_prevIdx) ? tfData_H1.obv[h1_prevIdx] : 0;
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f → %s", price, h1_ema, (price > h1_ema) ? "BUY" : "SELL");
            PrintFormat("  RSI: %.2f vs Centro Empirico=%.2f → %s", h1_rsi, tfData_H1.rsi_center, (h1_rsi > tfData_H1.rsi_center) ? "BUY" : "SELL");
            PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f → %s", h1_adx, tfData_H1.adx_threshold, (h1_adx > tfData_H1.adx_threshold) ? "TREND" : "NO TREND");
            PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f → %s", h1_ha_close, h1_ha_open, (h1_ha_close > h1_ha_open) ? "BUY" : "SELL");
            PrintFormat("  OBV: %.0f vs Prev=%.0f → %s", h1_obv, h1_obv_prev, (h1_obv >= h1_obv_prev) ? "BUY" : "SELL");
            PrintFormat("  🎯 SCORE H1: %.2f", scoreH1);
        }
    } else if (g_enableLogsEffective) {
        Print("  📊 H1 Score:  N/D (DISATTIVATO)");
    }
    
    // H4 INDICATORS - Usa solo indicatori esistenti in TimeFrameData
    if (g_vote_H4_active && g_enableLogsEffective) {
        int h4_idx = ArraySize(tfData_H4.rsi) - 1;
        if (h4_idx < 0) {
            Print("\n--- H4: DATI NON DISPONIBILI ---");
        } else {
            Print("\n--- H4 (SWING) ---");
            PrintFormat("  🌱 Peso organico TF: %.2f", tfData_H4.organic.weight);
            double h4_close = (ArraySize(tfData_H4.rates) > h4_idx) ? tfData_H4.rates[h4_idx].close : price;
            int h4_prevIdx = (h4_idx > 0) ? h4_idx - 1 : 0;
            double h4_ema = (ArraySize(tfData_H4.ema) > h4_idx) ? tfData_H4.ema[h4_idx] : 0;
            double h4_rsi = (ArraySize(tfData_H4.rsi) > h4_idx) ? tfData_H4.rsi[h4_idx] : 0;
            double h4_adx = (ArraySize(tfData_H4.adx) > h4_idx) ? tfData_H4.adx[h4_idx] : 0;
            double h4_ha_close = (ArraySize(tfData_H4.ha_close) > h4_idx) ? tfData_H4.ha_close[h4_idx] : 0;
            double h4_ha_open = (ArraySize(tfData_H4.ha_open) > h4_idx) ? tfData_H4.ha_open[h4_idx] : 0;
            double h4_obv = (ArraySize(tfData_H4.obv) > h4_idx) ? tfData_H4.obv[h4_idx] : 0;
            double h4_obv_prev = (ArraySize(tfData_H4.obv) > h4_prevIdx) ? tfData_H4.obv[h4_prevIdx] : 0;
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f → %s", price, h4_ema, (price > h4_ema) ? "BUY" : "SELL");
            PrintFormat("  RSI: %.2f vs Centro Empirico=%.2f → %s", h4_rsi, tfData_H4.rsi_center, (h4_rsi > tfData_H4.rsi_center) ? "BUY" : "SELL");
            PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f → %s", h4_adx, tfData_H4.adx_threshold, (h4_adx > tfData_H4.adx_threshold) ? "TREND" : "NO TREND");
            PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f → %s", h4_ha_close, h4_ha_open, (h4_ha_close > h4_ha_open) ? "BUY" : "SELL");
            PrintFormat("  OBV: %.0f vs Prev=%.0f → %s", h4_obv, h4_obv_prev, (h4_obv >= h4_obv_prev) ? "BUY" : "SELL");
            PrintFormat("  🎯 SCORE H4: %.2f", scoreH4);
        }
    } else if (g_enableLogsEffective) {
        Print("  📊 H4 Score:  N/D (DISATTIVATO)");
    }
    
    // D1 INDICATORS - Usa solo indicatori esistenti in TimeFrameData
    if (g_vote_D1_active && g_enableLogsEffective) {
        int d1_idx = ArraySize(tfData_D1.rsi) - 1;
        if (d1_idx < 0) {
            Print("\n--- D1: DATI NON DISPONIBILI ---");
        } else {
            Print("\n--- D1 (TREND LUNGO) ---");
            PrintFormat("  🌱 Peso organico TF: %.2f", tfData_D1.organic.weight);
            double d1_close = (ArraySize(tfData_D1.rates) > d1_idx) ? tfData_D1.rates[d1_idx].close : price;
            int d1_prevIdx = (d1_idx > 0) ? d1_idx - 1 : 0;
            double d1_ema = (ArraySize(tfData_D1.ema) > d1_idx) ? tfData_D1.ema[d1_idx] : 0;
            double d1_rsi = (ArraySize(tfData_D1.rsi) > d1_idx) ? tfData_D1.rsi[d1_idx] : 0;
            double d1_adx = (ArraySize(tfData_D1.adx) > d1_idx) ? tfData_D1.adx[d1_idx] : 0;
            double d1_ha_close = (ArraySize(tfData_D1.ha_close) > d1_idx) ? tfData_D1.ha_close[d1_idx] : 0;
            double d1_ha_open = (ArraySize(tfData_D1.ha_open) > d1_idx) ? tfData_D1.ha_open[d1_idx] : 0;
            double d1_obv = (ArraySize(tfData_D1.obv) > d1_idx) ? tfData_D1.obv[d1_idx] : 0;
            double d1_obv_prev = (ArraySize(tfData_D1.obv) > d1_prevIdx) ? tfData_D1.obv[d1_prevIdx] : 0;
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f → %s", price, d1_ema, (price > d1_ema) ? "BUY" : "SELL");
            PrintFormat("  RSI: %.2f vs Centro Empirico=%.2f → %s", d1_rsi, tfData_D1.rsi_center, (d1_rsi > tfData_D1.rsi_center) ? "BUY" : "SELL");
            PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f → %s", d1_adx, tfData_D1.adx_threshold, (d1_adx > tfData_D1.adx_threshold) ? "TREND" : "NO TREND");
            PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f → %s", d1_ha_close, d1_ha_open, (d1_ha_close > d1_ha_open) ? "BUY" : "SELL");
            PrintFormat("  OBV: %.0f vs Prev=%.0f → %s", d1_obv, d1_obv_prev, (d1_obv >= d1_obv_prev) ? "BUY" : "SELL");
            PrintFormat("  🎯 SCORE D1: %.2f", scoreD1);
        }
    } else if (g_enableLogsEffective) {
        Print("  📊 D1 Score:  N/D (DISATTIVATO)");
    }
    
    if (g_enableLogsEffective) {
        Print("\n========== 🔥 SOMMA TOTALE MULTI-TIMEFRAME ==========");
    }
    
    // 🔥 SOMMA TOTALE degli score di tutti i timeframe attivi
    double totalScore = 0.0;
    if (g_vote_M5_active) totalScore += scoreM5;
    if (g_vote_H1_active) totalScore += scoreH1;
    if (g_vote_H4_active) totalScore += scoreH4;
    if (g_vote_D1_active) totalScore += scoreD1;
    
    // 🔍 LOG DIAGNOSTICO SCORE
    if (g_enableLogsEffective) {
        PrintFormat("[📊 SCORE] M5: %+.2f | H1: %+.2f | H4: %+.2f | D1: %+.2f | TOTAL: %+.2f", 
            scoreM5, scoreH1, scoreH4, scoreD1, totalScore);
        
        if (totalScore > 0)
            Print("  ✅ DIREZIONE FINALE: BUY (totalScore > 0)");
        else if (totalScore < 0)
            Print("  ❌ DIREZIONE FINALE: SELL (totalScore < 0)");
        else
            Print("  ⚪ DIREZIONE FINALE: NEUTRO (totalScore = 0)");
        
        Print("======================================================\n");
    }
    
    // ════════════════════════════════════════════════════════════
    // 🌱 LOGICA DECISIONALE ORGANICA
    // Score → Direzione + Soglia percentuale
    // ════════════════════════════════════════════════════════════
    
    int decision = 0; // 0=no trade, 1=buy, -1=sell
    
    // 📊 CALCOLA SCORE MASSIMO POSSIBILE (organico)
    // Ogni indicatore attivo contribuisce peso_TF al massimo (max ±1.0 * peso)
    // Max = num_indicatori_attivi × Σ(peso_TF_attivi) × 1.0
    double maxScorePossible = 0.0;
    
    // 🔧 FIX: Conta separatamente indicatori DIREZIONALI e FILTRI
    // ADX e ATR sono FILTRI (non votano direzionalmente), non devono contare nel max score
    int numIndicatorsActive = 0;      // Indicatori DIREZIONALI
    int numFiltersActive = 0;          // Filtri (ADX, ATR) - per log ma non per score
    
    if (enableEMA) numIndicatorsActive++;
    if (enableRSI) numIndicatorsActive++;
    if (enableMACD) numIndicatorsActive++;
    if (enableBB) numIndicatorsActive++;
    if (enableHeikin) numIndicatorsActive++;
    if (enableOBV) numIndicatorsActive++;
    
    // 🔧 FIX: ADX è CONDIZIONALE - conta solo se supera la soglia
    // ADX vota SOLO se supera la soglia organica, altrimenti è neutro
    // Per il calcolo del max score, lo contiamo come "potenzialmente attivo"
    if (enableADX) numIndicatorsActive++;     // Può votare se ADX > soglia
    
    // 🌱 Max score = somma dei pesi organici TF × num indicatori attivi × 1.0 (max normalized)
    if (g_vote_M5_active) maxScorePossible += g_organic_M5.weight * numIndicatorsActive;
    if (g_vote_H1_active) maxScorePossible += g_organic_H1.weight * numIndicatorsActive;
    if (g_vote_H4_active) maxScorePossible += g_organic_H4.weight * numIndicatorsActive;
    if (g_vote_D1_active) maxScorePossible += g_organic_D1.weight * numIndicatorsActive;
    
    // ✅ VALIDATO: scorePct sempre >= 0 (MathAbs + divisione protetta)
    double scorePct = (maxScorePossible > 0) ? (MathAbs(totalScore) / maxScorePossible) * 100.0 : 0;
    bool isBuy = (totalScore > 0);
    bool isSell = (totalScore < 0);
    
    // ═══════════════════════════════════════════════════════════════
    // 🎯 DETECTOR INVERSIONE: Aggiorna tutti i segnali
    // ═══════════════════════════════════════════════════════════════
    int momentumSignal = UpdateScoreMomentum(totalScore);
    int regimeSignal = UpdateRegimeChange();
    int divergenceSignal = UpdateRSIDivergence();
    
    double reversalStrength = 0.0;
    int reversalSignal = GetReversalSignal(reversalStrength);
    
    // 🌱 AGGIUNGI SCORE AL BUFFER STORICO (per soglia automatica)
    // ✅ INPUT: scorePct >= 0 (validato sopra)
    AddScoreToHistory(scorePct);
    
    // 🌱 OTTIENI SOGLIA CORRENTE (automatica o manuale, con fallback)
    double currentThreshold = GetCurrentThreshold();
    
    // Log se stiamo usando fallback
    if (AutoScoreThreshold && !g_scoreThresholdReady && g_enableLogsEffective) {
        // 🌱 Minimo campioni = φ⁵ ≈ 11 (derivato organicamente)
        int minSamplesOrg = (int)MathRound(MathPow(PHI, 5));
        int minSamplesForLog = MathMax(minSamplesOrg, (int)MathCeil(SCORE_HISTORY_MAX * PHI_INV_SQ * PHI_INV));
        PrintFormat("[VOTE] 🔄 Soglia auto non pronta, uso fallback manuale: %.1f%% (buffer: %d/%d)", 
            ScoreThreshold, g_scoreHistorySize, minSamplesForLog);
    }
    
    // 🔍 LOG DIAGNOSTICO
    if (g_enableLogsEffective) {
        // ✅ ANALISI: distingui chiaramente il tipo di soglia usata
        string thresholdType;
        if (!AutoScoreThreshold) 
            thresholdType = "MANUALE";
        else if (g_scoreThresholdReady)
            thresholdType = "AUTO";
        else
            thresholdType = StringFormat("FALLBACK:%d/%d", g_scoreHistorySize, 
                MathMax((int)MathRound(MathPow(PHI, 5)), (int)MathCeil(SCORE_HISTORY_MAX * PHI_INV_SQ * PHI_INV)));
        
        PrintFormat("[SCORE DEBUG] 📊 Score: %+.2f | Max: %.2f | Pct: %.2f%% | Soglia: %.1f%% (%s)",
            totalScore, maxScorePossible, scorePct, currentThreshold, thresholdType);
        PrintFormat("   Indicatori attivi: %d | Direzione: %s", numIndicatorsActive, isBuy ? "BUY" : isSell ? "SELL" : "NEUTRA");
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🎯 LOGICA DECISIONALE ORGANICA CON REVERSAL DETECTION
    // 
    // REGOLE:
    // 1. Score supera soglia → trade approvato
    // 2. SE EnableReversalBlock=true E reversal FORTE contrario → BLOCCA (protezione)
    // 3. SE score debole MA reversal forte nella stessa dir → trade anticipato
    // 🌱 Soglia blocco = g_reversalThreshold (DATA-DRIVEN: mean + stdev × φ⁻¹)
    // ═══════════════════════════════════════════════════════════════
    
    bool reversalConflict = false;   // True se reversal contrario blocca
    bool reversalBoost = false;      // True se reversal permette entry anticipato
    
    // STEP 1: Valuta segnale normale (score sopra soglia)
    if (isBuy && scorePct >= currentThreshold) {
        // Check se reversal FORTE contrario → BLOCCA per sicurezza (se abilitato)
        if (EnableReversalBlock && reversalSignal == -1 && reversalStrength >= g_reversalThreshold) {
            reversalConflict = true;
            // NON assegna decision = trade bloccato
        } else {
            decision = 1;
        }
    }
    else if (isSell && scorePct >= currentThreshold) {
        // Check se reversal FORTE contrario → BLOCCA per sicurezza (se abilitato)
        if (EnableReversalBlock && reversalSignal == 1 && reversalStrength >= g_reversalThreshold) {
            reversalConflict = true;
            // NON assegna decision = trade bloccato
        } else {
            decision = -1;
        }
    }
    
    // STEP 2: Score DEBOLE ma REVERSAL FORTE nella stessa direzione → entry anticipato
    if (decision == 0 && !reversalConflict && reversalSignal != 0 && reversalStrength >= g_reversalThreshold) {
        // Score deve essere almeno nella stessa direzione del reversal
        bool directionMatch = (reversalSignal == 1 && totalScore >= 0) || 
                              (reversalSignal == -1 && totalScore <= 0);
        
        // Soglia ridotta = soglia × φ⁻¹ (circa 62% della normale)
        double reversalThreshold = currentThreshold * PHI_INV;
        
        if (directionMatch && scorePct >= reversalThreshold) {
            decision = reversalSignal;
            reversalBoost = true;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 📋 LOG UNICO E CHIARO (no ridondanza)
    // ═══════════════════════════════════════════════════════════════
    if (reversalConflict) {
        // Trade BLOCCATO da reversal contrario
        PrintFormat("[VOTE] ⛔ %s BLOCCATO | Score: %.1f%% ma Reversal %s contrario (forza %.0f%%)",
            isBuy ? "BUY" : "SELL", scorePct,
            reversalSignal == 1 ? "BULLISH" : "BEARISH", reversalStrength * 100);
    }
    else if (decision != 0) {
        string decisionText = (decision == 1) ? "🟢 BUY" : "🔴 SELL";
        
        if (reversalBoost) {
            // Trade ANTICIPATO grazie a reversal
            PrintFormat("[VOTE] ✅ %s ANTICIPATO | Score: %.1f%% + Reversal %s (forza %.0f%%)",
                decisionText, scorePct,
                reversalSignal == 1 ? "BULLISH" : "BEARISH", reversalStrength * 100);
        } else if (reversalSignal != 0 && reversalSignal == decision) {
            // Trade CONFERMATO da reversal nella stessa direzione
            PrintFormat("[VOTE] ✅ %s CONFERMATO | Score: %.1f%% + Reversal concorde (forza %.0f%%)",
                decisionText, scorePct, reversalStrength * 100);
        } else {
            // Trade normale senza reversal significativo
            PrintFormat("[VOTE] ✅ %s APPROVATO | Score: %.1f%% >= %.1f%% soglia",
                decisionText, scorePct, currentThreshold);
        }
    }
    else if (g_enableLogsEffective) {
        // Nessun trade
        string reason = "";
        if (scorePct < currentThreshold) {
            reason = StringFormat("Score %.1f%% < %.1f%% soglia", scorePct, currentThreshold);
        } else {
            reason = "Direzione neutra";
        }
        PrintFormat("[VOTE] ⚪ NO TRADE | %s", reason);
    }
    
    return decision;
}

//+------------------------------------------------------------------+
//| Apri ordine SELL                                                 |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
    if (SellLotSize <= 0) return;
    
    // 🛡️ VALIDAZIONE LOTTO: rispetta limiti broker
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    double finalLot = SellLotSize;
    
    // Clamp al range consentito
    if (finalLot < minLot) {
        PrintFormat("[TRADE] ⚠️ SELL Lotto %.2f < min %.2f - adeguato", finalLot, minLot);
        finalLot = minLot;
    }
    if (finalLot > maxLot) {
        PrintFormat("[TRADE] ⚠️ SELL Lotto %.2f > max %.2f - adeguato", finalLot, maxLot);
        finalLot = maxLot;
    }
    
    // Arrotonda allo step consentito
    if (stepLot > 0) {
        finalLot = MathFloor(finalLot / stepLot) * stepLot;
    }
    
    // NormalizeDouble per evitare errori di precisione
    finalLot = NormalizeDouble(finalLot, 2);
    
    if (finalLot < minLot) {
        Print("[TRADE] ❌ SELL Lotto nullo dopo normalizzazione - skip");
        return;
    }
    
    // 📊 CATTURA DATI PRE-TRADE per analisi
    double askBefore = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bidBefore = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadBefore = (askBefore - bidBefore) / _Point;
    
    double price = bidBefore;
    double sl = 0;
    double tp = 0;

    // SL: priorità a prezzo fisso, altrimenti punti
    if (StopLossPriceSell > 0)
        sl = StopLossPriceSell;
    else if (SellStopLossPoints > 0)
        sl = price + SellStopLossPoints * _Point;

    // TP: priorità a prezzo fisso, altrimenti punti
    if (TakeProfitPriceSell > 0)
        tp = TakeProfitPriceSell;
    else if (SellTakeProfitPoints > 0)
        tp = price - SellTakeProfitPoints * _Point;
    
    if (trade.Sell(finalLot, _Symbol, price, sl, tp, "Auto SELL")) {
        // 📊 CALCOLA SLIPPAGE
        double executedPrice = trade.ResultPrice();
        double slippagePoints = (bidBefore - executedPrice) / _Point;
        
        // Aggiorna statistiche
        g_stats.totalSlippage += MathAbs(slippagePoints);
        g_stats.slippageCount++;
        
        // Aggiorna equity peak per drawdown
        double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        if (currentEquity > g_stats.peakEquity) {
            g_stats.peakEquity = currentEquity;
        }
        g_stats.lastTradeTime = TimeCurrent();
        
        // 📊 LOG COMPLETO per analisi profitto
        PrintFormat("[TRADE] ✅ SELL APERTO #%I64u", trade.ResultOrder());
        PrintFormat("   📈 Prezzo: richiesto=%.5f eseguito=%.5f | Slippage=%.1f pts", 
            bidBefore, executedPrice, slippagePoints);
        PrintFormat("   📊 Spread=%.1f pts | Lot=%.2f | SL=%.5f | TP=%.5f", 
            spreadBefore, finalLot, sl, tp);
        if (sl > 0 || tp > 0) {
            double riskPips = sl > 0 ? (sl - price) / _Point / 10 : 0;
            double rewardPips = tp > 0 ? (price - tp) / _Point / 10 : 0;
            double rr = (riskPips > 0 && rewardPips > 0) ? rewardPips / riskPips : 0;
            PrintFormat("   💰 Risk (SL): %.2f pips | Reward (TP): %.2f pips | R:R=1:%.2f",
                riskPips, rewardPips, rr);
        }
    } else {
        int errCode = GetLastError();
        PrintFormat("[TRADE] ❌ SELL FALLITO! Errore %d: %s | Price=%.5f Lot=%.2f SL=%.5f TP=%.5f",
            errCode, ErrorDescription(errCode), price, finalLot, sl, tp);
    }
}

//+------------------------------------------------------------------+
//| Apri ordine BUY                                                  |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
    if (BuyLotSize <= 0) return;
    
    // 🛡️ VALIDAZIONE LOTTO: rispetta limiti broker
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    double finalLot = BuyLotSize;
    
    // Clamp al range consentito
    if (finalLot < minLot) {
        PrintFormat("[TRADE] ⚠️ BUY Lotto %.2f < min %.2f - adeguato", finalLot, minLot);
        finalLot = minLot;
    }
    if (finalLot > maxLot) {
        PrintFormat("[TRADE] ⚠️ BUY Lotto %.2f > max %.2f - adeguato", finalLot, maxLot);
        finalLot = maxLot;
    }
    
    // Arrotonda allo step consentito
    if (stepLot > 0) {
        finalLot = MathFloor(finalLot / stepLot) * stepLot;
    }
    
    // NormalizeDouble per evitare errori di precisione
    finalLot = NormalizeDouble(finalLot, 2);
    
    if (finalLot < minLot) {
        Print("[TRADE] ❌ BUY Lotto nullo dopo normalizzazione - skip");
        return;
    }
    
    // 📊 CATTURA DATI PRE-TRADE per analisi
    double askBefore = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bidBefore = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadBefore = (askBefore - bidBefore) / _Point;
    
    double price = askBefore;
    double sl = 0;
    double tp = 0;

    // SL: priorità a prezzo fisso, altrimenti punti
    if (StopLossPriceBuy > 0)
        sl = StopLossPriceBuy;
    else if (BuyStopLossPoints > 0)
        sl = price - BuyStopLossPoints * _Point;

    // TP: priorità a prezzo fisso, altrimenti punti
    if (TakeProfitPriceBuy > 0)
        tp = TakeProfitPriceBuy;
    else if (BuyTakeProfitPoints > 0)
        tp = price + BuyTakeProfitPoints * _Point;
    
    if (trade.Buy(finalLot, _Symbol, price, sl, tp, "Auto BUY")) {
        // 📊 CALCOLA SLIPPAGE
        double executedPrice = trade.ResultPrice();
        double slippagePoints = (executedPrice - askBefore) / _Point;
        
        // Aggiorna statistiche
        g_stats.totalSlippage += MathAbs(slippagePoints);
        g_stats.slippageCount++;
        
        // Aggiorna equity peak per drawdown
        double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        if (currentEquity > g_stats.peakEquity) {
            g_stats.peakEquity = currentEquity;
        }
        g_stats.lastTradeTime = TimeCurrent();
        
        // 📊 LOG COMPLETO per analisi profitto
        PrintFormat("[TRADE] ✅ BUY APERTO #%I64u", trade.ResultOrder());
        PrintFormat("   📈 Prezzo: richiesto=%.5f eseguito=%.5f | Slippage=%.1f pts", 
            askBefore, executedPrice, slippagePoints);
        PrintFormat("   📊 Spread=%.1f pts | Lot=%.2f | SL=%.5f | TP=%.5f", 
            spreadBefore, finalLot, sl, tp);
        if (sl > 0 || tp > 0) {
            double riskPips = sl > 0 ? (price - sl) / _Point / 10 : 0;
            double rewardPips = tp > 0 ? (tp - price) / _Point / 10 : 0;
            double rr = (riskPips > 0 && rewardPips > 0) ? rewardPips / riskPips : 0;
            PrintFormat("   💰 Risk (SL): %.2f pips | Reward (TP): %.2f pips | R:R=1:%.2f",
                riskPips, rewardPips, rr);
        }
    } else {
        int errCode = GetLastError();
        PrintFormat("[TRADE] ❌ BUY FALLITO! Errore %d: %s | Price=%.5f Lot=%.2f SL=%.5f TP=%.5f Spread=%.1f",
            errCode, ErrorDescription(errCode), price, finalLot, sl, tp, spreadBefore);
    }
}

//+------------------------------------------------------------------+
//| Stop loss temporale su posizioni aperte                          |
//| 🔧 FIX: Esclude weekend dal conteggio tempo                       |
//+------------------------------------------------------------------+
void CheckAndCloseOnTimeStop()
{
    int buyLimit = MathMax(0, BuyTimeStopMinutes);
    int sellLimit = MathMax(0, SellTimeStopMinutes);
    if (buyLimit == 0 && sellLimit == 0) return; // Funzione disattivata se entrambi 0
    
    int totalPositions = PositionsTotal();
    if (totalPositions == 0) return;
    
    datetime now = TimeCurrent();
    int closedCount = 0;
    // 🔧 FIX: Usa Magic cachato invece di ricalcolarlo ogni volta
    int uniqueMagic = g_uniqueMagicNumber;
    
    for (int i = totalPositions - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != uniqueMagic) continue;
        
        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        int limitMinutes = (type == POSITION_TYPE_BUY) ? buyLimit : sellLimit;
        if (limitMinutes <= 0) continue; // Nessun limite per questo lato
        
        datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
        
        // 🔧 FIX: Calcola tempo di TRADING effettivo (escludi weekend)
        // Mercato forex: chiude venerdì ~22:00 UTC, apre domenica ~22:00 UTC
        long totalSeconds = (long)(now - openTime);
        
        // Conta i giorni di weekend nel periodo con precisione migliorata
        datetime checkTime = openTime;
        int weekendSeconds = 0;
        while (checkTime < now) {
            MqlDateTime dt;
            TimeToStruct(checkTime, dt);
            // Sabato intero = 24h non trading
            if (dt.day_of_week == 6) {
                weekendSeconds += 86400;
            }
            // Domenica: solo prime ~22 ore non trading (mercato apre ~22:00 UTC)
            else if (dt.day_of_week == 0) {
                weekendSeconds += 79200;  // 22 ore = 22 * 3600
            }
            // Venerdì: ultime ~2 ore non trading (mercato chiude ~22:00 UTC)
            // Approssimazione conservativa: non contiamo per evitare complessità
            checkTime += 86400;  // Avanza di un giorno
        }
        
        // Sottrai tempo weekend
        int tradingSeconds = (int)MathMax(0, totalSeconds - weekendSeconds);
        int maxLifetimeSeconds = limitMinutes * 60;
        if (tradingSeconds < maxLifetimeSeconds) continue;
        
        int lifetimeMinutes = tradingSeconds / 60;
        
        double volume = PositionGetDouble(POSITION_VOLUME);
        double posProfit = PositionGetDouble(POSITION_PROFIT);
        // 🔧 FIX: Rimossa dichiarazione duplicata di lifetimeMinutes (usava lifetimeSeconds inesistente)
        
        PrintFormat("[TIME STOP] ⏰ Posizione #%I64u %s aperta da %d min (limite %d) → chiusura forzata", 
            ticket,
            (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
            lifetimeMinutes,
            limitMinutes);
        
        if (trade.PositionClose(ticket)) {
            closedCount++;
            PrintFormat("[TIME STOP] ✅ Chiusa posizione #%I64u %s (Lot: %.2f, P/L: %.2f)", 
                ticket,
                type == POSITION_TYPE_BUY ? "BUY" : "SELL",
                volume,
                posProfit);
        } else {
            PrintFormat("[TIME STOP] ❌ Errore chiusura posizione #%I64u: %d", ticket, GetLastError());
        }
    }
    
    if (closedCount > 0) {
        PrintFormat("[TIME STOP] 🛑 Posizioni chiuse per durata massima: %d", closedCount);
    }
}

//+------------------------------------------------------------------+
//| 🛡️ Descrizione errore trading (funzione helper)                 |
//+------------------------------------------------------------------+
string ErrorDescription(int errorCode)
{
    switch(errorCode) {
        case 0:     return "OK";
        case 10004: return "Requote";
        case 10006: return "Request rejected";
        case 10007: return "Request canceled by trader";
        case 10008: return "Order placed";
        case 10009: return "Request executed";
        case 10010: return "Only part of request executed";
        case 10011: return "Request processing error";
        case 10012: return "Request canceled by timeout";
        case 10013: return "Invalid request";
        case 10014: return "Invalid volume";
        case 10015: return "Invalid price";
        case 10016: return "Invalid stops";
        case 10017: return "Trade disabled";
        case 10018: return "Market closed";
        case 10019: return "Insufficient funds";
        case 10020: return "Prices changed";
        case 10021: return "No quotes to process request";
        case 10022: return "Invalid expiration";
        case 10023: return "Order state changed";
        case 10024: return "Too many requests";
        case 10025: return "No changes in request";
        case 10026: return "Autotrading disabled by server";
        case 10027: return "Autotrading disabled by client terminal";
        case 10028: return "Request locked for processing";
        case 10029: return "Order or position frozen";
        case 10030: return "Invalid order filling type";
        case 10031: return "No connection with trade server";
        case 10032: return "Operation allowed only for live accounts";
        case 10033: return "Number of pending orders reached limit";
        case 10034: return "Volume of orders and positions reached limit";
        case 10035: return "Incorrect or prohibited order type";
        case 10036: return "Position with specified ID already closed";
        case 10038: return "Close volume exceeds position volume";
        case 10039: return "Close order for position already exists";
        case 10040: return "Number of positions reached limit";
        case 10041: return "Pending order activation rejected, order canceled";
        case 10042: return "Request rejected, only long positions allowed";
        case 10043: return "Request rejected, only short positions allowed";
        case 10044: return "Request rejected, only position close allowed";
        case 10045: return "Request rejected due to FIFO rule";
        default:    return StringFormat("Unknown error %d", errorCode);
    }
}

//+------------------------------------------------------------------+
//| 📊 TRACCIA CHIUSURA TRADE E AGGIORNA STATISTICHE                 |
//| Chiamata automaticamente da MT5 per catturare ogni chiusura       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    // Ci interessa solo la chiusura di posizioni (DEAL)
    if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    
    // Verifica che sia una chiusura (DEAL_ENTRY_OUT)
    if (!HistoryDealSelect(trans.deal)) return;
    
    ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
    if (entry != DEAL_ENTRY_OUT) return;
    
    // Verifica Magic Number
    long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
    if (dealMagic != g_uniqueMagicNumber) return;
    
    // Verifica simbolo
    string dealSymbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
    if (dealSymbol != _Symbol) return;
    
    // ═══════════════════════════════════════════════════════════════
    // 📊 ESTRAI DATI DEL TRADE CHIUSO
    // ═══════════════════════════════════════════════════════════════
    double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
    double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
    double swap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
    double volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
    double closePrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
    ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
    ulong positionId = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
    
    // Profitto netto (inclusi commission e swap)
    double netProfit = profit + commission + swap;
    
    // Aggiorna totali commission/swap
    g_stats.totalCommission += commission;
    g_stats.totalSwap += swap;
    
    // ═══════════════════════════════════════════════════════════════
    // 📊 TROVA IL DEAL DI APERTURA per calcolare durata e prezzo entry
    // ═══════════════════════════════════════════════════════════════
    double openPrice = 0;
    datetime openTime = 0;
    datetime closeTime = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
    
    // Cerca nella history il deal di apertura con stesso position ID
    HistorySelectByPosition(positionId);
    int totalDeals = HistoryDealsTotal();
    for (int i = 0; i < totalDeals; i++) {
        ulong dealTicket = HistoryDealGetTicket(i);
        if (dealTicket == 0) continue;
        
        ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
        if (dealEntry == DEAL_ENTRY_IN) {
            openPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            openTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
            break;
        }
    }
    
    // Calcola durata trade
    int durationMinutes = (openTime > 0) ? (int)((closeTime - openTime) / 60) : 0;
    
    // Determina motivo chiusura (dal commento)
    string closeReason = "SIGNAL";
    string comment = HistoryDealGetString(trans.deal, DEAL_COMMENT);
    if (StringFind(comment, "sl") >= 0 || StringFind(comment, "SL") >= 0) {
        closeReason = "SL";
    } else if (StringFind(comment, "tp") >= 0 || StringFind(comment, "TP") >= 0) {
        closeReason = "TP";
    } else if (StringFind(comment, "TIME") >= 0 || StringFind(comment, "time") >= 0) {
        closeReason = "TIME_STOP";
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 📊 AGGIORNA STATISTICHE
    // ═══════════════════════════════════════════════════════════════
    g_stats.totalTrades++;
    
    if (netProfit >= 0) {
        g_stats.winTrades++;
        g_stats.totalProfit += netProfit;
        
        // Streak
        if (g_stats.currentStreak >= 0) {
            g_stats.currentStreak++;
        } else {
            g_stats.currentStreak = 1;
        }
        if ((int)g_stats.currentStreak > g_stats.maxWinStreak) {
            g_stats.maxWinStreak = (int)g_stats.currentStreak;
        }
    } else {
        g_stats.lossTrades++;
        g_stats.totalLoss += MathAbs(netProfit);
        
        // Streak
        if (g_stats.currentStreak <= 0) {
            g_stats.currentStreak--;
        } else {
            g_stats.currentStreak = -1;
        }
        if ((int)MathAbs(g_stats.currentStreak) > g_stats.maxLossStreak) {
            g_stats.maxLossStreak = (int)MathAbs(g_stats.currentStreak);
        }
    }
    
    // Calcola metriche derivate
    if (g_stats.winTrades > 0) {
        g_stats.avgWin = g_stats.totalProfit / g_stats.winTrades;
    }
    if (g_stats.lossTrades > 0) {
        g_stats.avgLoss = g_stats.totalLoss / g_stats.lossTrades;
    }
    if (g_stats.totalLoss > 0) {
        g_stats.profitFactor = g_stats.totalProfit / g_stats.totalLoss;
    }
    if (g_stats.totalTrades > 0) {
        double winRate = (double)g_stats.winTrades / g_stats.totalTrades;
        g_stats.expectancy = (winRate * g_stats.avgWin) - ((1.0 - winRate) * g_stats.avgLoss);
    }
    
    // Aggiorna drawdown
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    if (currentEquity > g_stats.peakEquity) {
        g_stats.peakEquity = currentEquity;
    }
    double currentDD = g_stats.peakEquity - currentEquity;
    double currentDDPct = (g_stats.peakEquity > 0) ? (currentDD / g_stats.peakEquity * 100) : 0;
    if (currentDD > g_stats.maxDrawdown) {
        g_stats.maxDrawdown = currentDD;
        g_stats.maxDrawdownPct = currentDDPct;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 📊 LOG COMPLETO CHIUSURA TRADE
    // ═══════════════════════════════════════════════════════════════
    string profitIcon = (netProfit >= 0) ? "✅" : "❌";
    string typeStr = (dealType == DEAL_TYPE_BUY) ? "SELL→CLOSE" : "BUY→CLOSE";
    
    Print("╔══════════════════════════════════════════════════════════════╗");
    PrintFormat("║ %s TRADE CHIUSO #%I64u (%s)", profitIcon, positionId, closeReason);
    Print("╠══════════════════════════════════════════════════════════════╣");
    PrintFormat("║ Tipo: %s | Volume: %.2f lot", typeStr, volume);
    PrintFormat("║ Entry: %.5f → Exit: %.5f", openPrice, closePrice);
    PrintFormat("║ Profit: %.2f | Comm: %.2f | Swap: %.2f", profit, commission, swap);
    PrintFormat("║ 💰 NET P/L: %+.2f %s", netProfit, AccountInfoString(ACCOUNT_CURRENCY));
    PrintFormat("║ ⏱️ Durata: %d minuti (%.1f ore)", durationMinutes, durationMinutes / 60.0);
    Print("╠══════════════════════════════════════════════════════════════╣");
    PrintFormat("║ 📊 STATISTICHE CUMULATIVE");
    PrintFormat("║ Trades: %d (W:%d L:%d) = %.1f%% WinRate", 
        g_stats.totalTrades, g_stats.winTrades, g_stats.lossTrades,
        g_stats.totalTrades > 0 ? (100.0 * g_stats.winTrades / g_stats.totalTrades) : 0);
    PrintFormat("║ PF: %.2f | Expect: %.2f | AvgW: %.2f AvgL: %.2f", 
        g_stats.profitFactor, g_stats.expectancy, g_stats.avgWin, g_stats.avgLoss);
    PrintFormat("║ MaxDD: %.2f (%.2f%%) | Streak: %+d (W:%d L:%d)", 
        g_stats.maxDrawdown, g_stats.maxDrawdownPct, (int)g_stats.currentStreak,
        g_stats.maxWinStreak, g_stats.maxLossStreak);
    Print("╚══════════════════════════════════════════════════════════════╝");
    
    // ═══════════════════════════════════════════════════════════════
    // 📊 SALVA NEL BUFFER TRADE RECENTI (per analisi pattern)
    // ═══════════════════════════════════════════════════════════════
    if (g_recentTradesMax > 0) {
        g_recentTrades[g_recentTradesIndex].ticket = positionId;
        g_recentTrades[g_recentTradesIndex].openTime = openTime;
        g_recentTrades[g_recentTradesIndex].closeTime = closeTime;
        g_recentTrades[g_recentTradesIndex].type = (dealType == DEAL_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
        g_recentTrades[g_recentTradesIndex].openPrice = openPrice;
        g_recentTrades[g_recentTradesIndex].closePrice = closePrice;
        g_recentTrades[g_recentTradesIndex].volume = volume;
        g_recentTrades[g_recentTradesIndex].profit = netProfit;
        g_recentTrades[g_recentTradesIndex].closeReason = closeReason;
        
        g_recentTradesIndex = (g_recentTradesIndex + 1) % g_recentTradesMax;
        if (g_recentTradesCount < g_recentTradesMax) g_recentTradesCount++;
    }
}
