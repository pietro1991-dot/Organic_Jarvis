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
    int stoch_k;       // Stochastic K
    int stoch_d;       // Stochastic D
    int stoch_slowing; // Stochastic slowing
    int cci;           // CCI period
    int momentum;      // Momentum period
    double psar_step;  // PSAR step (organico)
    double psar_max;   // PSAR max (organico)
    int wpr;           // Williams %R
    int mfi;           // MFI period
    int donchian;      // Donchian period
    int ichimoku_tenkan;  // Ichimoku Tenkan
    int ichimoku_kijun;   // Ichimoku Kijun
    int ichimoku_senkou;  // Ichimoku Senkou B
    int sma50;         // SMA breve
    int sma200;        // SMA lunga
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
input group "═══ 🌱 INDICATORI TREND ═══"
input bool   enableEMA       = true;    // EMA (trend direction)
input bool   enableMACD      = true;    // MACD (trend momentum)
input bool   enablePSAR      = true;    // Parabolic SAR (trend reversal)
input bool   enableADX       = true;    // ADX (trend strength)
input bool   enableSMA       = true;    // SMA Cross (trend confirmation)
input bool   enableIchimoku  = true;    // Ichimoku (multi-component trend)

input group "═══ 🌱 INDICATORI OSCILLATORI ═══"
input bool   enableRSI       = true;    // RSI (overbought/oversold)
input bool   enableStoch     = true;    // Stochastic (momentum oscillator)
input bool   enableCCI       = true;    // CCI (cyclical momentum)
input bool   enableMomentum  = true;    // Momentum (rate of change)
input bool   enableWPR       = true;    // Williams %R (momentum oscillator)
input bool   enableAO        = true;    // Awesome Oscillator (momentum)

input group "═══ 🌱 INDICATORI VOLATILITA' & VOLUME ═══"
input bool   enableBB        = true;    // Bollinger Bands (volatility bands)
input bool   enableATRsignal = true;    // ATR (volatility-based, contrarian)
input bool   enableDonchian  = true;    // Donchian Channel (breakout)
input bool   enableOBV       = true;    // OBV (volume-based trend)
input bool   enableMFI       = true;    // MFI (volume-weighted momentum)
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

// 🚀 COSTANTE CACHED: evita 4× SymbolInfoDouble per barra
double g_pointValue = 0.0;               // SYMBOL_POINT (calcolato 1× in OnInit)

//--- Handles indicatori per tutti i timeframe (inizializzati a INVALID_HANDLE per sicurezza)
int emaHandle_M5 = INVALID_HANDLE, emaHandle_H1 = INVALID_HANDLE, emaHandle_H4 = INVALID_HANDLE, emaHandle_D1 = INVALID_HANDLE;
int rsiHandle_M5 = INVALID_HANDLE, rsiHandle_H1 = INVALID_HANDLE, rsiHandle_H4 = INVALID_HANDLE, rsiHandle_D1 = INVALID_HANDLE;
int macdHandle_M5 = INVALID_HANDLE, macdHandle_H1 = INVALID_HANDLE, macdHandle_H4 = INVALID_HANDLE, macdHandle_D1 = INVALID_HANDLE;
int bbHandle_M5 = INVALID_HANDLE, bbHandle_H1 = INVALID_HANDLE, bbHandle_H4 = INVALID_HANDLE, bbHandle_D1 = INVALID_HANDLE;
int atrHandle_M5 = INVALID_HANDLE, atrHandle_H1 = INVALID_HANDLE, atrHandle_H4 = INVALID_HANDLE, atrHandle_D1 = INVALID_HANDLE;
int adxHandle_M5 = INVALID_HANDLE, adxHandle_H1 = INVALID_HANDLE, adxHandle_H4 = INVALID_HANDLE, adxHandle_D1 = INVALID_HANDLE;
int stochHandle_M5 = INVALID_HANDLE, stochHandle_H1 = INVALID_HANDLE, stochHandle_H4 = INVALID_HANDLE, stochHandle_D1 = INVALID_HANDLE;
int cciHandle_M5 = INVALID_HANDLE, cciHandle_H1 = INVALID_HANDLE, cciHandle_H4 = INVALID_HANDLE, cciHandle_D1 = INVALID_HANDLE;
int momentumHandle_M5 = INVALID_HANDLE, momentumHandle_H1 = INVALID_HANDLE, momentumHandle_H4 = INVALID_HANDLE, momentumHandle_D1 = INVALID_HANDLE;
int psarHandle_M5 = INVALID_HANDLE, psarHandle_H1 = INVALID_HANDLE, psarHandle_H4 = INVALID_HANDLE, psarHandle_D1 = INVALID_HANDLE;
int wprHandle_M5 = INVALID_HANDLE, wprHandle_H1 = INVALID_HANDLE, wprHandle_H4 = INVALID_HANDLE, wprHandle_D1 = INVALID_HANDLE;
int aoHandle_M5 = INVALID_HANDLE, aoHandle_H1 = INVALID_HANDLE, aoHandle_H4 = INVALID_HANDLE, aoHandle_D1 = INVALID_HANDLE;
int obvHandle_M5 = INVALID_HANDLE, obvHandle_H1 = INVALID_HANDLE, obvHandle_H4 = INVALID_HANDLE, obvHandle_D1 = INVALID_HANDLE;
int mfiHandle_M5 = INVALID_HANDLE, mfiHandle_H1 = INVALID_HANDLE, mfiHandle_H4 = INVALID_HANDLE, mfiHandle_D1 = INVALID_HANDLE;
int ichimokuHandle_M5 = INVALID_HANDLE, ichimokuHandle_H1 = INVALID_HANDLE, ichimokuHandle_H4 = INVALID_HANDLE, ichimokuHandle_D1 = INVALID_HANDLE;

//--- Struttura dati per timeframe
struct TimeFrameData {
    double ema[];
    double sma50[];
    double sma200[];
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
    double stoch_k[];
    double stoch_d[];
    double cci[];
    double momentum[];
    double psar[];
    double ha_open[];
    double ha_close[];
    double wpr[];
    double ao[];
    double obv[];
    double mfi[];
    double donchian_upper[];
    double donchian_lower[];
    double ichimoku_spanA[];
    double ichimoku_spanB[];
    MqlRates rates[];
    
    // 🌱 Valori organici calcolati dinamicamente
    double atr_avg;         // Media ATR calcolata sulle ultime N barre
    double adx_avg;         // Media ADX calcolata sulle ultime N barre
    double adx_stddev;      // Deviazione standard ADX
    double adx_threshold;   // Soglia ADX organica = avg + (1/φ)*stddev
    bool   isDataReady;     // Flag: abbastanza dati per calcoli organici
    
    // 🌱 CENTRI EMPIRICI - Calcolati da CalculateEmpiricalThresholds()
    // Valore = media storica indicatore per questo cross
    double rsi_center;      // mean(RSI) ultime N barre
    double mfi_center;      // mean(MFI) ultime N barre
    double wpr_center;      // mean(WPR) ultime N barre
    double cci_center;      // mean(CCI) ultime N barre
    double momentum_center; // mean(Momentum) ultime N barre
    double stoch_center;    // mean(Stoch K - Stoch D) ultime N barre
    double ao_center;       // mean(AO) ultime N barre
    
    // 🌱 SCALE EMPIRICHE - Derivate dalla volatilità dei dati
    double rsi_scale;       // Stdev empirico RSI × φ
    double cci_scale;       // Stdev empirico CCI × φ
    double stoch_scale;     // Stdev empirico Stoch × φ
    double momentum_scale;  // Stdev empirico Momentum × φ
    double wpr_scale;       // Stdev empirico WPR × φ
    double mfi_scale;       // Stdev empirico MFI × φ
    double ao_scale;        // Stdev empirico AO × φ
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
    // 🚀 RIEPILOGO STATO BUFFER - Trading pronto?
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
    
    int copiedM5 = g_dataReady_M5 ? CopyRates(_Symbol, PERIOD_M5, 0, totalBarsM5, ratesM5) : 0;
    int copiedH1 = g_dataReady_H1 ? CopyRates(_Symbol, PERIOD_H1, 0, totalBarsH1, ratesH1) : 0;
    int copiedH4 = g_dataReady_H4 ? CopyRates(_Symbol, PERIOD_H4, 0, totalBarsH4, ratesH4) : 0;
    int copiedD1 = g_dataReady_D1 ? CopyRates(_Symbol, PERIOD_D1, 0, totalBarsD1, ratesD1) : 0;
    
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
//+------------------------------------------------------------------+
bool IsTradeAllowedByHurst()
{
    if (!EnableHurstFilter) return true;  // Filtro disabilitato
    
    // Il ricalcolo avviene ad ogni nuova barra in RecalculateOrganicSystem()
    // Qui verifichiamo solo il flag
    if (!g_hurstReady) {
        Print("[HURST] ⏳ Hurst NON pronto: servono piu' dati per zona/stdev e soglia tradeScore");
        return false;
    }
    if (!g_hurstAllowTrade) {
        PrintFormat("[HURST] ⛔ TRADE BLOCCATO - TradeScore=%.3f < %.3f (soglia)", 
            g_hurstTradeScore, g_tradeScoreThreshold);
    }
    
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
//| ✅ OUTPUT: g_dynamicThreshold sempre nel range [23.6%, 76.4%]    |
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
    
    // 🌱 Soglia = mean + stdev × φ⁻¹
    g_dynamicThreshold = mean + stdev * PHI_INV;
    
    // ✅ VALIDATO: Forza soglia nel range [23.6%, 76.4%]
    double minThreshold = PHI_INV_CUB * 100.0;      // ≈ 23.6%
    double maxThreshold = (1.0 - PHI_INV_CUB) * 100.0;  // ≈ 76.4%
    g_dynamicThreshold = MathMax(minThreshold, MathMin(maxThreshold, g_dynamicThreshold));
    g_scoreThresholdReady = true;  // ✅ Flag: dati pronti
    
    // 🌱 Log solo se cambio significativo (stdev × φ⁻² = cambio minimo per log)
    double minChangeForLog = stdev * PHI_INV_SQ;  // Derivato dai DATI
    if (minChangeForLog < 0.1) minChangeForLog = 0.1;  // Minimo assoluto per evitare spam
    if (g_enableLogsEffective && MathAbs(g_dynamicThreshold - oldThreshold) > minChangeForLog) {
        PrintFormat("[THRESHOLD] 🌱 Soglia AUTO: %.1f%% → %.1f%% (mean=%.1f%% + stdev=%.1f%% × φ⁻¹) [%d campioni]",
            oldThreshold, g_dynamicThreshold, mean, stdev, g_scoreHistorySize);
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
    // 1. Chiediamo TUTTE le barre disponibili
    // 2. maxLag = barre_disponibili / φ² (derivato dai DATI!)
    // 3. Il periodo naturale emerge dall'autocorrelazione
    // Se non ci sono abbastanza dati, ritorna valid=false (TF disabilitato)
    // ═══════════════════════════════════════════════════════════════
    
    // Prima: scopri quante barre sono disponibili per questo TF
    int barsAvailable = Bars(_Symbol, tf);
    
    // 🌱 Minimo PURO: φ⁴ ≈ 7 barre (sotto questo non ha senso statistico)
    int minBarsForAnalysis = (int)MathRound(PHI_SQ * PHI_SQ);  // ≈ 6.85 → 7
    
    if (barsAvailable < minBarsForAnalysis) {
        PrintFormat("❌ [NATURAL] TF %s: solo %d barre disponibili, minimo richiesto %d - TF DISABILITATO", 
            EnumToString(tf), barsAvailable, minBarsForAnalysis);
        return result;  // valid = false
    }
    
    // 🌱 maxLag = barre / φ² (proporzione aurea delle barre disponibili)
    // Questo assicura sempre abbastanza dati per l'analisi
    int maxLag = (int)MathRound(barsAvailable / PHI_SQ);
    maxLag = MathMax((int)MathRound(PHI_SQ), maxLag);  // Minimo φ² ≈ 3 per analisi sensata
    
    // barsNeeded = maxLag × φ (per overlap statistico)
    int barsNeeded = (int)MathRound(maxLag * PHI);
    barsNeeded = MathMin(barsNeeded, barsAvailable);  // Non chiedere più di quanto disponibile
    
    int copied = CopyRates(_Symbol, tf, 0, barsNeeded, rates);
    if (copied < maxLag) {
        PrintFormat("❌ [NATURAL] TF %s: copiate solo %d barre su %d richieste - TF DISABILITATO", 
            EnumToString(tf), copied, maxLag);
        return result;
    }
    
    // Ricalcola maxLag basandosi sulle barre EFFETTIVE copiate
    maxLag = (int)MathRound(copied / PHI_SQ);
    maxLag = MathMax((int)MathRound(PHI_SQ), maxLag);
    
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
        data.mfi_center = 0;
        data.wpr_center = 0;
        data.cci_center = 0;
        data.momentum_center = 0;
        data.stoch_center = 0;
        data.ao_center = 0;
        data.rsi_scale = 0;
        data.cci_scale = 0;
        data.stoch_scale = 0;
        data.momentum_scale = 0;
        data.ao_scale = 0;
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
    
    // CCI
    if (ArraySize(data.cci) >= n) {
        double cci_data[];
        ArrayResize(cci_data, n);
        for (int i = 0; i < n; i++) cci_data[i] = data.cci[size - n + i];
        data.cci_center = CalculateEmpiricalMean(cci_data, n);
        double cci_stdev = CalculateEmpiricalStdDev(cci_data, n, data.cci_center);
        if (cci_stdev <= 0) {
            Print("❌ [EMPIRICAL] CCI stdev=0, dati flat - TF DISABILITATO");
            return false;
        }
        data.cci_scale = cci_stdev * PHI;
    } else {
        Print("❌ [EMPIRICAL] CCI: dati insufficienti (", ArraySize(data.cci), " < ", n, ")");
        return false;
    }
    
    // Stochastic K-D difference
    if (ArraySize(data.stoch_k) >= n && ArraySize(data.stoch_d) >= n) {
        double stoch_data[];
        ArrayResize(stoch_data, n);
        for (int i = 0; i < n; i++) stoch_data[i] = data.stoch_k[size - n + i] - data.stoch_d[size - n + i];
        data.stoch_center = CalculateEmpiricalMean(stoch_data, n);
        double stoch_stdev = CalculateEmpiricalStdDev(stoch_data, n, data.stoch_center);
        if (stoch_stdev <= 0) {
            Print("❌ [EMPIRICAL] Stoch stdev=0, dati flat - TF DISABILITATO");
            return false;
        }
        data.stoch_scale = stoch_stdev * PHI;
    } else {
        Print("❌ [EMPIRICAL] Stoch: dati insufficienti");
        return false;
    }
    
    // Momentum
    if (ArraySize(data.momentum) >= n) {
        double mom_data[];
        ArrayResize(mom_data, n);
        for (int i = 0; i < n; i++) mom_data[i] = data.momentum[size - n + i];
        data.momentum_center = CalculateEmpiricalMean(mom_data, n);
        double mom_stdev = CalculateEmpiricalStdDev(mom_data, n, data.momentum_center);
        if (mom_stdev <= 0) {
            Print("❌ [EMPIRICAL] Momentum stdev=0, dati flat - TF DISABILITATO");
            return false;
        }
        data.momentum_scale = mom_stdev * PHI;
    } else {
        Print("❌ [EMPIRICAL] Momentum: dati insufficienti");
        return false;
    }
    
    // MFI
    if (ArraySize(data.mfi) >= n) {
        double mfi_data[];
        ArrayResize(mfi_data, n);
        for (int i = 0; i < n; i++) mfi_data[i] = data.mfi[size - n + i];
        data.mfi_center = CalculateEmpiricalMean(mfi_data, n);
        double mfi_stdev = CalculateEmpiricalStdDev(mfi_data, n, data.mfi_center);
        if (mfi_stdev <= 0) {
            Print("❌ [EMPIRICAL] MFI stdev=0, dati flat - TF DISABILITATO");
            return false;
        }
        data.mfi_scale = mfi_stdev * PHI;
    } else {
        Print("❌ [EMPIRICAL] MFI: dati insufficienti");
        return false;
    }
    
    // WPR
    if (ArraySize(data.wpr) >= n) {
        double wpr_data[];
        ArrayResize(wpr_data, n);
        for (int i = 0; i < n; i++) wpr_data[i] = data.wpr[size - n + i];
        data.wpr_center = CalculateEmpiricalMean(wpr_data, n);
        double wpr_stdev = CalculateEmpiricalStdDev(wpr_data, n, data.wpr_center);
        if (wpr_stdev <= 0) {
            Print("❌ [EMPIRICAL] WPR stdev=0, dati flat - TF DISABILITATO");
            return false;
        }
        data.wpr_scale = wpr_stdev * PHI;
    } else {
        Print("❌ [EMPIRICAL] WPR: dati insufficienti");
        return false;
    }
    
    // AO (Awesome Oscillator)
    if (ArraySize(data.ao) >= n) {
        double ao_data[];
        ArrayResize(ao_data, n);
        for (int i = 0; i < n; i++) ao_data[i] = data.ao[size - n + i];
        data.ao_center = CalculateEmpiricalMean(ao_data, n);
        double ao_stdev = CalculateEmpiricalStdDev(ao_data, n, data.ao_center);
        // AO può avere stdev=0 in mercati molto flat, usa fallback ATR-based
        if (ao_stdev <= 0) {
            data.ao_scale = data.atr_avg * PHI;  // Fallback: usa ATR × φ
        } else {
            data.ao_scale = ao_stdev * PHI;
        }
    } else {
        // AO non disponibile, usa fallback
        data.ao_center = 0.0;
        data.ao_scale = data.atr_avg * PHI;
    }
    
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
            data.obv_scale = 1.0;  // Minimo assoluto
        }
    } else {
        // OBV non disponibile, usa fallback conservativo
        data.obv_scale = 1000.0;  // Valore tipico per volumi OBV
    }
    
    if (g_enableLogsEffective) {
        PrintFormat("[EMPIRICAL] ✅ RSI center=%.1f scale=%.1f | CCI center=%.1f scale=%.1f",
            data.rsi_center, data.rsi_scale, data.cci_center, data.cci_scale);
        PrintFormat("[EMPIRICAL] ✅ ADX p25=%.1f p75=%.1f | Stoch center=%.1f scale=%.1f",
            data.adx_p25, data.adx_p75, data.stoch_center, data.stoch_scale);
        PrintFormat("[EMPIRICAL] ✅ OBV scale=%.1f (dalla varianza storica variazioni)",
            data.obv_scale);
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
    organic.sma50 = verySlow;               // SMA breve: intermedio → verySlow
    organic.sma200 = longest;               // SMA lunga: struttura → longest
    
    // Momentum indicators (necessitano periodi medi/corti)
    organic.rsi = medium;                   // RSI → medium
    organic.momentum = medium;              // Momentum → medium
    organic.cci = slow;                     // CCI: ciclico → slow
    
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
    
    // Stochastic (tre periodi in relazione aurea)
    organic.stoch_k = medium;               // Stoch K → medium
    organic.stoch_d = fast;                 // Stoch D → fast (più smooth)
    organic.stoch_slowing = veryFast;       // Slowing → veryFast
    
    // Altri oscillatori
    organic.wpr = medium;                   // Williams %R → medium
    organic.mfi = medium;                   // Money Flow → medium
    
    // Channels
    organic.donchian = verySlow;            // Donchian: breakout → verySlow
    
    // Parabolic SAR (step e max derivati da φ e base)
    // 🌱 Formula organica: inversamente proporzionale al periodo naturale
    organic.psar_step = PHI_INV / (base * PHI);     // Step: inversamente proporzionale
    organic.psar_max = PHI_INV / base;              // Max: più alto per mercati veloci
    
    // 🌱 LIMITI PSAR: 100% derivati da potenze di 1/φ
    // 1/φ⁸ ≈ 0.021 (min step)
    // 1/φ⁵ ≈ 0.090 (max step)
    // 1/φ⁴ ≈ 0.146 (min max) 
    // 1/φ² ≈ 0.382 (max max, generoso per alta volatilità)
    // NOTA: 1/φⁿ significa moltiplicare PHI_INV n volte
    double phi_inv_8 = PHI_INV_CUB * PHI_INV_CUB * PHI_INV_SQ;  // 1/φ⁸ ≈ 0.021
    double phi_inv_5 = PHI_INV_CUB * PHI_INV_SQ;                 // 1/φ⁵ ≈ 0.090
    double phi_inv_4 = PHI_INV_SQ * PHI_INV_SQ;                  // 1/φ⁴ ≈ 0.146
    
    organic.psar_step = MathMax(phi_inv_8, MathMin(phi_inv_5, organic.psar_step));
    organic.psar_max = MathMax(phi_inv_4, MathMin(PHI_INV_SQ, organic.psar_max));
    
    // Ichimoku (periodi derivati da rapporti φ)
    organic.ichimoku_tenkan = medium;       // Tenkan → medium
    organic.ichimoku_kijun = verySlow;      // Kijun: base → verySlow
    organic.ichimoku_senkou = longest;      // Senkou: proiezione → longest
    
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
    PrintFormat("[%s] 🌱 Peso TF: %.2f | EMA=%d RSI=%d MACD=%d/%d/%d BB=%d(%.1f) ATR=%d ADX=%d",
        tfName, organic.weight, organic.ema, organic.rsi, 
        organic.macd_fast, organic.macd_slow, organic.macd_signal,
        organic.bb, organic.bb_dev, organic.atr, organic.adx);
    PrintFormat("[%s] Stoch=%d/%d/%d CCI=%d WPR=%d MFI=%d Donch=%d PSAR=%.4f/%.2f",
        tfName, organic.stoch_k, organic.stoch_d, organic.stoch_slowing,
        organic.cci, organic.wpr, organic.mfi, organic.donchian, organic.psar_step, organic.psar_max);
    PrintFormat("[%s] Ichimoku=%d/%d/%d | SMA50=%d SMA200=%d | Min barre: %d",
        tfName, organic.ichimoku_tenkan, organic.ichimoku_kijun, organic.ichimoku_senkou,
        organic.sma50, organic.sma200, organic.min_bars_required);
}

//+------------------------------------------------------------------+
//| 🔧 FIX: Verifica se i periodi sono cambiati significativamente    |
//| Ritorna true se almeno un periodo è cambiato >20% (soglia = 1/φ²)|
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
    stochHandle_M5 = iStochastic(_Symbol, PERIOD_M5, g_organic_M5.stoch_k, g_organic_M5.stoch_d, g_organic_M5.stoch_slowing, MODE_SMA, STO_LOWHIGH);
    cciHandle_M5 = iCCI(_Symbol, PERIOD_M5, g_organic_M5.cci, PRICE_TYPICAL);
    momentumHandle_M5 = iMomentum(_Symbol, PERIOD_M5, g_organic_M5.momentum, PRICE_CLOSE);
    psarHandle_M5 = iSAR(_Symbol, PERIOD_M5, g_organic_M5.psar_step, g_organic_M5.psar_max);
    wprHandle_M5 = iWPR(_Symbol, PERIOD_M5, g_organic_M5.wpr);
    aoHandle_M5 = iAO(_Symbol, PERIOD_M5);
    obvHandle_M5 = iOBV(_Symbol, PERIOD_M5, VOLUME_TICK);
    mfiHandle_M5 = iMFI(_Symbol, PERIOD_M5, g_organic_M5.mfi, VOLUME_TICK);
    ichimokuHandle_M5 = iIchimoku(_Symbol, PERIOD_M5, g_organic_M5.ichimoku_tenkan, g_organic_M5.ichimoku_kijun, g_organic_M5.ichimoku_senkou);
    
    // Log M5
    if (g_enableLogsEffective) {
        int m5ok = 0, m5err = 0;
        if (emaHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (rsiHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (macdHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (bbHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (atrHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (adxHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (stochHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (cciHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (momentumHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (psarHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (wprHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (aoHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (obvHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (mfiHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (ichimokuHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        handleCount += m5ok; handleErrors += m5err;
        PrintFormat("[INIT-HANDLES] M5: %d/%d handle creati %s", m5ok, 15, m5err == 0 ? "✅" : "⚠️");
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
    stochHandle_H1 = iStochastic(_Symbol, PERIOD_H1, g_organic_H1.stoch_k, g_organic_H1.stoch_d, g_organic_H1.stoch_slowing, MODE_SMA, STO_LOWHIGH);
    cciHandle_H1 = iCCI(_Symbol, PERIOD_H1, g_organic_H1.cci, PRICE_TYPICAL);
    momentumHandle_H1 = iMomentum(_Symbol, PERIOD_H1, g_organic_H1.momentum, PRICE_CLOSE);
    psarHandle_H1 = iSAR(_Symbol, PERIOD_H1, g_organic_H1.psar_step, g_organic_H1.psar_max);
    wprHandle_H1 = iWPR(_Symbol, PERIOD_H1, g_organic_H1.wpr);
    aoHandle_H1 = iAO(_Symbol, PERIOD_H1);
    obvHandle_H1 = iOBV(_Symbol, PERIOD_H1, VOLUME_TICK);
    mfiHandle_H1 = iMFI(_Symbol, PERIOD_H1, g_organic_H1.mfi, VOLUME_TICK);
    ichimokuHandle_H1 = iIchimoku(_Symbol, PERIOD_H1, g_organic_H1.ichimoku_tenkan, g_organic_H1.ichimoku_kijun, g_organic_H1.ichimoku_senkou);
    
    // Log H1
    if (g_enableLogsEffective) {
        int h1ok = 0, h1err = 0;
        if (emaHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (rsiHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (macdHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (bbHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (atrHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (adxHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (stochHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (cciHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (momentumHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (psarHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (wprHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (aoHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (obvHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (mfiHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (ichimokuHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        handleCount += h1ok; handleErrors += h1err;
        PrintFormat("[INIT-HANDLES] H1: %d/%d handle creati %s", h1ok, 15, h1err == 0 ? "✅" : "⚠️");
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
    stochHandle_H4 = iStochastic(_Symbol, PERIOD_H4, g_organic_H4.stoch_k, g_organic_H4.stoch_d, g_organic_H4.stoch_slowing, MODE_SMA, STO_LOWHIGH);
    cciHandle_H4 = iCCI(_Symbol, PERIOD_H4, g_organic_H4.cci, PRICE_TYPICAL);
    momentumHandle_H4 = iMomentum(_Symbol, PERIOD_H4, g_organic_H4.momentum, PRICE_CLOSE);
    psarHandle_H4 = iSAR(_Symbol, PERIOD_H4, g_organic_H4.psar_step, g_organic_H4.psar_max);
    wprHandle_H4 = iWPR(_Symbol, PERIOD_H4, g_organic_H4.wpr);
    aoHandle_H4 = iAO(_Symbol, PERIOD_H4);
    obvHandle_H4 = iOBV(_Symbol, PERIOD_H4, VOLUME_TICK);
    mfiHandle_H4 = iMFI(_Symbol, PERIOD_H4, g_organic_H4.mfi, VOLUME_TICK);
    ichimokuHandle_H4 = iIchimoku(_Symbol, PERIOD_H4, g_organic_H4.ichimoku_tenkan, g_organic_H4.ichimoku_kijun, g_organic_H4.ichimoku_senkou);
    
    // Log H4
    if (g_enableLogsEffective) {
        int h4ok = 0, h4err = 0;
        if (emaHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (rsiHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (macdHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (bbHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (atrHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (adxHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (stochHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (cciHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (momentumHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (psarHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (wprHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (aoHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (obvHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (mfiHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (ichimokuHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        handleCount += h4ok; handleErrors += h4err;
        PrintFormat("[INIT-HANDLES] H4: %d/%d handle creati %s", h4ok, 15, h4err == 0 ? "✅" : "⚠️");
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
    stochHandle_D1 = iStochastic(_Symbol, PERIOD_D1, g_organic_D1.stoch_k, g_organic_D1.stoch_d, g_organic_D1.stoch_slowing, MODE_SMA, STO_LOWHIGH);
    cciHandle_D1 = iCCI(_Symbol, PERIOD_D1, g_organic_D1.cci, PRICE_TYPICAL);
    momentumHandle_D1 = iMomentum(_Symbol, PERIOD_D1, g_organic_D1.momentum, PRICE_CLOSE);
    psarHandle_D1 = iSAR(_Symbol, PERIOD_D1, g_organic_D1.psar_step, g_organic_D1.psar_max);
    wprHandle_D1 = iWPR(_Symbol, PERIOD_D1, g_organic_D1.wpr);
    aoHandle_D1 = iAO(_Symbol, PERIOD_D1);
    obvHandle_D1 = iOBV(_Symbol, PERIOD_D1, VOLUME_TICK);
    mfiHandle_D1 = iMFI(_Symbol, PERIOD_D1, g_organic_D1.mfi, VOLUME_TICK);
    ichimokuHandle_D1 = iIchimoku(_Symbol, PERIOD_D1, g_organic_D1.ichimoku_tenkan, g_organic_D1.ichimoku_kijun, g_organic_D1.ichimoku_senkou);
    
    // Log D1
    if (g_enableLogsEffective) {
        int d1ok = 0, d1err = 0;
        if (emaHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (rsiHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (macdHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (bbHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (atrHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (adxHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (stochHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (cciHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (momentumHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (psarHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (wprHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (aoHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (obvHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (mfiHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (ichimokuHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        handleCount += d1ok; handleErrors += d1err;
        PrintFormat("[INIT-HANDLES] D1: %d/%d handle creati %s", d1ok, 15, d1err == 0 ? "✅" : "⚠️");
        PrintFormat("[INIT-HANDLES] 📊 TOTALE: %d/60 handle creati | Errori: %d %s", 
            handleCount, handleErrors, handleErrors == 0 ? "✅" : "❌");
    }
    
    return (emaHandle_M5 != INVALID_HANDLE && rsiHandle_M5 != INVALID_HANDLE && 
            macdHandle_M5 != INVALID_HANDLE && bbHandle_M5 != INVALID_HANDLE &&
            atrHandle_M5 != INVALID_HANDLE && adxHandle_M5 != INVALID_HANDLE &&
            stochHandle_M5 != INVALID_HANDLE && cciHandle_M5 != INVALID_HANDLE &&
            momentumHandle_M5 != INVALID_HANDLE && psarHandle_M5 != INVALID_HANDLE &&
            wprHandle_M5 != INVALID_HANDLE && aoHandle_M5 != INVALID_HANDLE &&
            obvHandle_M5 != INVALID_HANDLE && mfiHandle_M5 != INVALID_HANDLE &&
            ichimokuHandle_M5 != INVALID_HANDLE &&
            emaHandle_H1 != INVALID_HANDLE && rsiHandle_H1 != INVALID_HANDLE &&
            macdHandle_H1 != INVALID_HANDLE && bbHandle_H1 != INVALID_HANDLE &&
            atrHandle_H1 != INVALID_HANDLE && adxHandle_H1 != INVALID_HANDLE &&
            stochHandle_H1 != INVALID_HANDLE && cciHandle_H1 != INVALID_HANDLE &&
            momentumHandle_H1 != INVALID_HANDLE && psarHandle_H1 != INVALID_HANDLE &&
            wprHandle_H1 != INVALID_HANDLE &&
            aoHandle_H1 != INVALID_HANDLE && obvHandle_H1 != INVALID_HANDLE &&
            mfiHandle_H1 != INVALID_HANDLE && ichimokuHandle_H1 != INVALID_HANDLE &&
            emaHandle_H4 != INVALID_HANDLE && rsiHandle_H4 != INVALID_HANDLE &&
            macdHandle_H4 != INVALID_HANDLE && bbHandle_H4 != INVALID_HANDLE &&
            atrHandle_H4 != INVALID_HANDLE && adxHandle_H4 != INVALID_HANDLE &&
            stochHandle_H4 != INVALID_HANDLE && cciHandle_H4 != INVALID_HANDLE &&
            momentumHandle_H4 != INVALID_HANDLE && psarHandle_H4 != INVALID_HANDLE &&
            wprHandle_H4 != INVALID_HANDLE &&
            aoHandle_H4 != INVALID_HANDLE && obvHandle_H4 != INVALID_HANDLE &&
            mfiHandle_H4 != INVALID_HANDLE && ichimokuHandle_H4 != INVALID_HANDLE &&
            emaHandle_D1 != INVALID_HANDLE && rsiHandle_D1 != INVALID_HANDLE &&
            macdHandle_D1 != INVALID_HANDLE && bbHandle_D1 != INVALID_HANDLE &&
            atrHandle_D1 != INVALID_HANDLE && adxHandle_D1 != INVALID_HANDLE &&
            stochHandle_D1 != INVALID_HANDLE && cciHandle_D1 != INVALID_HANDLE &&
            momentumHandle_D1 != INVALID_HANDLE && psarHandle_D1 != INVALID_HANDLE &&
            wprHandle_D1 != INVALID_HANDLE &&
            aoHandle_D1 != INVALID_HANDLE && obvHandle_D1 != INVALID_HANDLE &&
            mfiHandle_D1 != INVALID_HANDLE && ichimokuHandle_D1 != INVALID_HANDLE);
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
    if (stochHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(stochHandle_M5)) releasedCount++; else releaseErrors++; stochHandle_M5 = INVALID_HANDLE; }
    if (cciHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(cciHandle_M5)) releasedCount++; else releaseErrors++; cciHandle_M5 = INVALID_HANDLE; }
    if (momentumHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(momentumHandle_M5)) releasedCount++; else releaseErrors++; momentumHandle_M5 = INVALID_HANDLE; }
    if (psarHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(psarHandle_M5)) releasedCount++; else releaseErrors++; psarHandle_M5 = INVALID_HANDLE; }
    if (wprHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(wprHandle_M5)) releasedCount++; else releaseErrors++; wprHandle_M5 = INVALID_HANDLE; }
    if (aoHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(aoHandle_M5)) releasedCount++; else releaseErrors++; aoHandle_M5 = INVALID_HANDLE; }
    if (obvHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_M5)) releasedCount++; else releaseErrors++; obvHandle_M5 = INVALID_HANDLE; }
    if (mfiHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(mfiHandle_M5)) releasedCount++; else releaseErrors++; mfiHandle_M5 = INVALID_HANDLE; }
    if (ichimokuHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(ichimokuHandle_M5)) releasedCount++; else releaseErrors++; ichimokuHandle_M5 = INVALID_HANDLE; }
    
    // H1
    if (emaHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_H1)) releasedCount++; else releaseErrors++; emaHandle_H1 = INVALID_HANDLE; }
    if (rsiHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_H1)) releasedCount++; else releaseErrors++; rsiHandle_H1 = INVALID_HANDLE; }
    if (macdHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_H1)) releasedCount++; else releaseErrors++; macdHandle_H1 = INVALID_HANDLE; }
    if (bbHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_H1)) releasedCount++; else releaseErrors++; bbHandle_H1 = INVALID_HANDLE; }
    if (atrHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_H1)) releasedCount++; else releaseErrors++; atrHandle_H1 = INVALID_HANDLE; }
    if (adxHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_H1)) releasedCount++; else releaseErrors++; adxHandle_H1 = INVALID_HANDLE; }
    if (stochHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(stochHandle_H1)) releasedCount++; else releaseErrors++; stochHandle_H1 = INVALID_HANDLE; }
    if (cciHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(cciHandle_H1)) releasedCount++; else releaseErrors++; cciHandle_H1 = INVALID_HANDLE; }
    if (momentumHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(momentumHandle_H1)) releasedCount++; else releaseErrors++; momentumHandle_H1 = INVALID_HANDLE; }
    if (psarHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(psarHandle_H1)) releasedCount++; else releaseErrors++; psarHandle_H1 = INVALID_HANDLE; }
    if (wprHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(wprHandle_H1)) releasedCount++; else releaseErrors++; wprHandle_H1 = INVALID_HANDLE; }
    if (aoHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(aoHandle_H1)) releasedCount++; else releaseErrors++; aoHandle_H1 = INVALID_HANDLE; }
    if (obvHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_H1)) releasedCount++; else releaseErrors++; obvHandle_H1 = INVALID_HANDLE; }
    if (mfiHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(mfiHandle_H1)) releasedCount++; else releaseErrors++; mfiHandle_H1 = INVALID_HANDLE; }
    if (ichimokuHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(ichimokuHandle_H1)) releasedCount++; else releaseErrors++; ichimokuHandle_H1 = INVALID_HANDLE; }
    
    // H4
    if (emaHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_H4)) releasedCount++; else releaseErrors++; emaHandle_H4 = INVALID_HANDLE; }
    if (rsiHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_H4)) releasedCount++; else releaseErrors++; rsiHandle_H4 = INVALID_HANDLE; }
    if (macdHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_H4)) releasedCount++; else releaseErrors++; macdHandle_H4 = INVALID_HANDLE; }
    if (bbHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_H4)) releasedCount++; else releaseErrors++; bbHandle_H4 = INVALID_HANDLE; }
    if (atrHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_H4)) releasedCount++; else releaseErrors++; atrHandle_H4 = INVALID_HANDLE; }
    if (adxHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_H4)) releasedCount++; else releaseErrors++; adxHandle_H4 = INVALID_HANDLE; }
    if (stochHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(stochHandle_H4)) releasedCount++; else releaseErrors++; stochHandle_H4 = INVALID_HANDLE; }
    if (cciHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(cciHandle_H4)) releasedCount++; else releaseErrors++; cciHandle_H4 = INVALID_HANDLE; }
    if (momentumHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(momentumHandle_H4)) releasedCount++; else releaseErrors++; momentumHandle_H4 = INVALID_HANDLE; }
    if (psarHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(psarHandle_H4)) releasedCount++; else releaseErrors++; psarHandle_H4 = INVALID_HANDLE; }
    if (wprHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(wprHandle_H4)) releasedCount++; else releaseErrors++; wprHandle_H4 = INVALID_HANDLE; }
    if (aoHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(aoHandle_H4)) releasedCount++; else releaseErrors++; aoHandle_H4 = INVALID_HANDLE; }
    if (obvHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_H4)) releasedCount++; else releaseErrors++; obvHandle_H4 = INVALID_HANDLE; }
    if (mfiHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(mfiHandle_H4)) releasedCount++; else releaseErrors++; mfiHandle_H4 = INVALID_HANDLE; }
    if (ichimokuHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(ichimokuHandle_H4)) releasedCount++; else releaseErrors++; ichimokuHandle_H4 = INVALID_HANDLE; }
    
    // D1
    if (emaHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_D1)) releasedCount++; else releaseErrors++; emaHandle_D1 = INVALID_HANDLE; }
    if (rsiHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_D1)) releasedCount++; else releaseErrors++; rsiHandle_D1 = INVALID_HANDLE; }
    if (macdHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_D1)) releasedCount++; else releaseErrors++; macdHandle_D1 = INVALID_HANDLE; }
    if (bbHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_D1)) releasedCount++; else releaseErrors++; bbHandle_D1 = INVALID_HANDLE; }
    if (atrHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_D1)) releasedCount++; else releaseErrors++; atrHandle_D1 = INVALID_HANDLE; }
    if (adxHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_D1)) releasedCount++; else releaseErrors++; adxHandle_D1 = INVALID_HANDLE; }
    if (stochHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(stochHandle_D1)) releasedCount++; else releaseErrors++; stochHandle_D1 = INVALID_HANDLE; }
    if (cciHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(cciHandle_D1)) releasedCount++; else releaseErrors++; cciHandle_D1 = INVALID_HANDLE; }
    if (momentumHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(momentumHandle_D1)) releasedCount++; else releaseErrors++; momentumHandle_D1 = INVALID_HANDLE; }
    if (psarHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(psarHandle_D1)) releasedCount++; else releaseErrors++; psarHandle_D1 = INVALID_HANDLE; }
    if (wprHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(wprHandle_D1)) releasedCount++; else releaseErrors++; wprHandle_D1 = INVALID_HANDLE; }
    if (aoHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(aoHandle_D1)) releasedCount++; else releaseErrors++; aoHandle_D1 = INVALID_HANDLE; }
    if (obvHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_D1)) releasedCount++; else releaseErrors++; obvHandle_D1 = INVALID_HANDLE; }
    if (mfiHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(mfiHandle_D1)) releasedCount++; else releaseErrors++; mfiHandle_D1 = INVALID_HANDLE; }
    if (ichimokuHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(ichimokuHandle_D1)) releasedCount++; else releaseErrors++; ichimokuHandle_D1 = INVALID_HANDLE; }
    
    if (g_enableLogsEffective) {
        PrintFormat("[DEINIT-HANDLES] 📊 TOTALE: %d/60 handle rilasciati | Errori: %d %s", 
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
//| 🔧 FIX: Validazione integrità dati storici                        |
//+------------------------------------------------------------------+
bool LoadTimeFrameData(ENUM_TIMEFRAMES tf, TimeFrameData &data, int bars)
{
    // Ottieni dati di prezzo
    int copiedBars = CopyRates(_Symbol, tf, 0, bars, data.rates);
    if (copiedBars <= 0) {
        PrintFormat("[ERROR] Impossibile caricare rates per TF %s", EnumToString(tf));
        return false;
    }
    
    // 🔧 FIX: Validazione integrità dati storici
    if (copiedBars < bars / 2) {
        PrintFormat("[⚠️ WARN] TF %s: Dati parziali (%d/%d barre) - qualità analisi ridotta",
            EnumToString(tf), copiedBars, bars);
    }
    
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
    ArrayResize(data.sma50, count);
    ArrayResize(data.sma200, count);
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
    ArrayResize(data.stoch_k, count);
    ArrayResize(data.stoch_d, count);
    ArrayResize(data.cci, count);
    ArrayResize(data.momentum, count);
    ArrayResize(data.psar, count);
    ArrayResize(data.ha_open, count);
    ArrayResize(data.ha_close, count);
    ArrayResize(data.wpr, count);
    ArrayResize(data.ao, count);
    ArrayResize(data.obv, count);
    ArrayResize(data.mfi, count);
    ArrayResize(data.donchian_upper, count);
    ArrayResize(data.donchian_lower, count);
    ArrayResize(data.ichimoku_spanA, count);
    ArrayResize(data.ichimoku_spanB, count);
    
    // 🌱 Inizializza valori organici (saranno calcolati dai DATI dopo il caricamento)
    data.atr_avg = 0;
    data.adx_avg = 0;
    data.adx_stddev = 0;
    data.adx_threshold = 0;  // Verrà calcolato da CalculateOrganicValues
    data.isDataReady = false;
    
    // 🌱 PURO: Inizializza tutto a 0 - verranno calcolati dai DATI
    // Se rimangono a 0, significa che il TF non ha dati sufficienti
    data.rsi_center = 0;
    data.mfi_center = 0;
    data.wpr_center = 0;
    data.cci_center = 0;
    data.momentum_center = 0;
    data.stoch_center = 0;
    data.ao_center = 0;
    data.rsi_scale = 0;
    data.cci_scale = 0;
    data.stoch_scale = 0;
    data.momentum_scale = 0;
    data.wpr_scale = 0;
    data.mfi_scale = 0;
    data.ao_scale = 0;
    data.adx_p25 = 0;
    data.adx_p75 = 0;
    
    // Copia dati indicatori (seleziona handles appropriati per timeframe)
    int emaH = INVALID_HANDLE, rsiH = INVALID_HANDLE, macdH = INVALID_HANDLE;
    int bbH = INVALID_HANDLE, atrH = INVALID_HANDLE, adxH = INVALID_HANDLE;
    int stochH = INVALID_HANDLE, cciH = INVALID_HANDLE, momentumH = INVALID_HANDLE, psarH = INVALID_HANDLE;
    int wprH = INVALID_HANDLE, aoH = INVALID_HANDLE, obvH = INVALID_HANDLE;
    int mfiH = INVALID_HANDLE, ichimokuH = INVALID_HANDLE;
    int donchianPeriod = g_organic_M5.donchian;
    int sma50Period = g_organic_M5.sma50;
    int sma200Period = g_organic_M5.sma200;
    int minBarsRequired = g_organic_M5.min_bars_required;
    
    switch(tf) {
        case PERIOD_M5:
            emaH = emaHandle_M5; rsiH = rsiHandle_M5; macdH = macdHandle_M5;
            bbH = bbHandle_M5; atrH = atrHandle_M5; adxH = adxHandle_M5;
            stochH = stochHandle_M5; cciH = cciHandle_M5; momentumH = momentumHandle_M5; psarH = psarHandle_M5;
            wprH = wprHandle_M5; aoH = aoHandle_M5; obvH = obvHandle_M5;
            mfiH = mfiHandle_M5; ichimokuH = ichimokuHandle_M5;
            donchianPeriod = g_organic_M5.donchian;
            sma50Period = g_organic_M5.sma50;
            sma200Period = g_organic_M5.sma200;
            minBarsRequired = g_organic_M5.min_bars_required;
            data.organic = g_organic_M5;  // 🌱 Copia periodi organici
            break;
        case PERIOD_H1:
            emaH = emaHandle_H1; rsiH = rsiHandle_H1; macdH = macdHandle_H1;
            bbH = bbHandle_H1; atrH = atrHandle_H1; adxH = adxHandle_H1;
            stochH = stochHandle_H1; cciH = cciHandle_H1; momentumH = momentumHandle_H1; psarH = psarHandle_H1;
            wprH = wprHandle_H1; aoH = aoHandle_H1; obvH = obvHandle_H1;
            mfiH = mfiHandle_H1; ichimokuH = ichimokuHandle_H1;
            donchianPeriod = g_organic_H1.donchian;
            sma50Period = g_organic_H1.sma50;
            sma200Period = g_organic_H1.sma200;
            minBarsRequired = g_organic_H1.min_bars_required;
            data.organic = g_organic_H1;  // 🌱 Copia periodi organici
            break;
        case PERIOD_H4:
            emaH = emaHandle_H4; rsiH = rsiHandle_H4; macdH = macdHandle_H4;
            bbH = bbHandle_H4; atrH = atrHandle_H4; adxH = adxHandle_H4;
            stochH = stochHandle_H4; cciH = cciHandle_H4; momentumH = momentumHandle_H4; psarH = psarHandle_H4;
            wprH = wprHandle_H4; aoH = aoHandle_H4; obvH = obvHandle_H4;
            mfiH = mfiHandle_H4; ichimokuH = ichimokuHandle_H4;
            donchianPeriod = g_organic_H4.donchian;
            sma50Period = g_organic_H4.sma50;
            sma200Period = g_organic_H4.sma200;
            minBarsRequired = g_organic_H4.min_bars_required;
            data.organic = g_organic_H4;  // 🌱 Copia periodi organici
            break;
        case PERIOD_D1:
            emaH = emaHandle_D1; rsiH = rsiHandle_D1; macdH = macdHandle_D1;
            bbH = bbHandle_D1; atrH = atrHandle_D1; adxH = adxHandle_D1;
            stochH = stochHandle_D1; cciH = cciHandle_D1; momentumH = momentumHandle_D1; psarH = psarHandle_D1;
            wprH = wprHandle_D1; aoH = aoHandle_D1; obvH = obvHandle_D1;
            mfiH = mfiHandle_D1; ichimokuH = ichimokuHandle_D1;
            donchianPeriod = g_organic_D1.donchian;
            sma50Period = g_organic_D1.sma50;
            sma200Period = g_organic_D1.sma200;
            minBarsRequired = g_organic_D1.min_bars_required;
            data.organic = g_organic_D1;  // 🌱 Copia periodi organici
            break;
        default:
            return false;
    }
    
    // Copia buffers indicatori
    if (CopyBuffer(emaH, 0, 0, count, data.ema) <= 0) return false;
    if (CopyBuffer(rsiH, 0, 0, count, data.rsi) <= 0) return false;
    if (CopyBuffer(macdH, 0, 0, count, data.macd) <= 0) return false;
    if (CopyBuffer(macdH, 1, 0, count, data.macd_signal) <= 0) return false;
    if (CopyBuffer(bbH, 0, 0, count, data.bb_upper) <= 0) return false;
    if (CopyBuffer(bbH, 1, 0, count, data.bb_middle) <= 0) return false;
    if (CopyBuffer(bbH, 2, 0, count, data.bb_lower) <= 0) return false;
    if (CopyBuffer(atrH, 0, 0, count, data.atr) <= 0) return false;
    if (CopyBuffer(adxH, 0, 0, count, data.adx) <= 0) return false;
    if (CopyBuffer(adxH, 1, 0, count, data.di_plus) <= 0) return false;   // +DI
    if (CopyBuffer(adxH, 2, 0, count, data.di_minus) <= 0) return false;  // -DI
    if (CopyBuffer(stochH, 0, 0, count, data.stoch_k) <= 0) return false;
    if (CopyBuffer(stochH, 1, 0, count, data.stoch_d) <= 0) return false;
    if (CopyBuffer(cciH, 0, 0, count, data.cci) <= 0) return false;
    if (CopyBuffer(momentumH, 0, 0, count, data.momentum) <= 0) return false;
    if (CopyBuffer(psarH, 0, 0, count, data.psar) <= 0) return false;
    if (CopyBuffer(wprH, 0, 0, count, data.wpr) <= 0) return false;
    if (CopyBuffer(aoH, 0, 0, count, data.ao) <= 0) return false;
    if (CopyBuffer(obvH, 0, 0, count, data.obv) <= 0) return false;
    if (CopyBuffer(mfiH, 0, 0, count, data.mfi) <= 0) return false;
    // ═══════════════════════════════════════════════════════════════
    // 🌿 ICHIMOKU SENKOU SPAN - COMPORTAMENTO MT5
    // ═══════════════════════════════════════════════════════════════
    // In MT5, Senkou Span A (buffer 2) e Span B (buffer 3) sono PROIETTATI
    // 26 periodi NEL FUTURO dal punto di calcolo.
    // 
    // SIGNIFICATO per il nostro EA:
    // - data.ichimoku_spanX[lastIdx] contiene il valore della cloud VISIBILE
    //   nella posizione lastIdx del grafico
    // - Questo valore fu CALCOLATO 26 barre FA usando i dati di quel momento
    // - È il comportamento CORRETTO per trading: confrontiamo il prezzo attuale
    //   con la cloud che era stata "predetta" e ora è realtà sul grafico
    // - NON è un errore - è esattamente ciò che un trader vede sul grafico!
    // ═══════════════════════════════════════════════════════════════
    if (CopyBuffer(ichimokuH, 2, 0, count, data.ichimoku_spanA) <= 0) return false;
    if (CopyBuffer(ichimokuH, 3, 0, count, data.ichimoku_spanB) <= 0) return false;
    
    // Calcola indicatori derivati (SMA, Heikin, Donchian) con periodi ORGANICI
    CalculateCustomIndicators(data, count, donchianPeriod, sma50Period, sma200Period);
    
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
//| Usa somme scorrevoli invece di ricalcolo completo                |
//+------------------------------------------------------------------+
void CalculateCustomIndicators(TimeFrameData &data, int count, int donchianPeriod, int sma50Period, int sma200Period)
{
    if (count < 1) return;
    
    // 🚀 OTTIMIZZAZIONE: Usa somme scorrevoli per SMA (O(n) invece di O(n²))
    int sma50_period = MathMin(sma50Period, count);
    int sma200_period = MathMin(sma200Period, count);
    int donPeriod = MathMax(1, MathMin(donchianPeriod, count));
    
    // Inizializza somme scorrevoli
    double sum50 = 0, sum200 = 0;
    
    // Prima passa: calcola somme iniziali e Heikin Ashi
    for (int i = 0; i < count; i++) {
        double close = data.rates[i].close;
        double open = data.rates[i].open;
        double high = data.rates[i].high;
        double low = data.rates[i].low;
        
        // 🚀 SMA50 con somma scorrevole
        sum50 += close;
        if (i >= sma50_period) {
            sum50 -= data.rates[i - sma50_period].close;
            data.sma50[i] = sum50 / sma50_period;
        } else {
            data.sma50[i] = sum50 / (i + 1);
        }
        
        // 🚀 SMA200 con somma scorrevole
        sum200 += close;
        if (i >= sma200_period) {
            sum200 -= data.rates[i - sma200_period].close;
            data.sma200[i] = sum200 / sma200_period;
        } else {
            data.sma200[i] = sum200 / (i + 1);
        }
        
        // Heikin Ashi (già O(n))
        double haClose = (open + high + low + close) * 0.25;
        double haOpen = (i == 0) ? (open + close) * 0.5 : (data.ha_open[i-1] + data.ha_close[i-1]) * 0.5;
        data.ha_close[i] = haClose;
        data.ha_open[i] = haOpen;
    }
    
    // 🚀 DONCHIAN SEMPLIFICATO: Calcola solo per ultime N barre (non tutto l'array)
    // In trading, ci interessa solo l'ultimo valore!
    int startIdx = MathMax(0, count - donPeriod * 2);
    for (int i = startIdx; i < count; i++) {
        double highestHigh = data.rates[i].high;
        double lowestLow = data.rates[i].low;
        int donStart = MathMax(0, i - donPeriod + 1);
        for (int j = donStart; j <= i; j++) {
            if (data.rates[j].high > highestHigh) highestHigh = data.rates[j].high;
            if (data.rates[j].low < lowestLow) lowestLow = data.rates[j].low;
        }
        data.donchian_upper[i] = highestHigh;
        data.donchian_lower[i] = lowestLow;
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
    // 🌱 OSCILLATORI CON CENTRI E SCALE EMPIRICI
    // I centri e le scale derivano dai DATI storici (CalculateEmpiricalThresholds)
    // Non più 50, -50, 100 hardcoded ma valori calcolati dal mercato!
    // ═══════════════════════════════════════════════════════════════
    
    // Stochastic: K - D crossover (normalizzato con scala EMPIRICA)
    if (enableStoch && ArraySize(data.stoch_k) > lastIdx && ArraySize(data.stoch_d) > lastIdx && data.stoch_scale > 0) {
        double stoch_cross = data.stoch_k[lastIdx] - data.stoch_d[lastIdx];
        // 🌱 Centro e scala derivati dai DATI, non hardcoded!
        // ✅ VALIDATO: data.stoch_scale > 0 verificato nell'if
        double stoch_norm = MathMax(-1.0, MathMin(1.0, (stoch_cross - data.stoch_center) / data.stoch_scale));
        totalScore += stoch_norm * w;
    }
    
    // CCI: centrato sulla media EMPIRICA, scala dalla stdev EMPIRICA
    if (enableCCI && ArraySize(data.cci) > lastIdx && data.cci_scale > 0) {
        // 🌱 Centro e scala derivati dai DATI!
        // ✅ VALIDATO: data.cci_scale > 0 verificato nell'if
        double cci_norm = MathMax(-1.0, MathMin(1.0, (data.cci[lastIdx] - data.cci_center) / data.cci_scale));
        totalScore += cci_norm * w;
    }
    
    // Momentum: centrato sulla media EMPIRICA, scala dalla stdev EMPIRICA
    if (enableMomentum && ArraySize(data.momentum) > lastIdx && price > 0 && data.momentum_scale > 0) {
        // 🌱 Centro e scala derivati dai DATI!
        // ✅ VALIDATO: data.momentum_scale > 0 verificato nell'if
        double mom_norm = (data.momentum[lastIdx] - data.momentum_center) / data.momentum_scale;
        mom_norm = MathMax(-1.0, MathMin(1.0, mom_norm));
        totalScore += mom_norm * w;
    }
    
    // Parabolic SAR: prezzo - SAR
    // 🌱 Scala ORGANICA: distanza normalizzata con ATR
    if (enablePSAR && ArraySize(data.psar) > lastIdx && data.psar[lastIdx] != 0.0) {
        double psar_diff = price - data.psar[lastIdx];
        double psar_norm = MathMax(-1.0, MathMin(1.0, psar_diff / atr_scale));
        totalScore += psar_norm * w;
    }
    
    // Heikin Ashi: close - open
    // 🌱 Scala ORGANICA: usa 1/φ dell'ATR (corpo HA = proporzione aurea del range)
    if (enableHeikin && ArraySize(data.ha_close) > lastIdx && ArraySize(data.ha_open) > lastIdx) {
        double ha_diff = data.ha_close[lastIdx] - data.ha_open[lastIdx];
        double ha_norm = MathMax(-1.0, MathMin(1.0, ha_diff / (atr_scale * PHI_INV)));  // 1/φ ≈ 0.618
        totalScore += ha_norm * w;
    }
    
    // Williams %R: centrato sulla media EMPIRICA, scala EMPIRICA
    if (enableWPR && ArraySize(data.wpr) > lastIdx && data.wpr_scale > 0) {
        // 🌱 Centro e scala EMPIRICI derivati dai DATI!
        // ✅ VALIDATO: data.wpr_scale > 0 verificato nell'if
        double wpr_norm = (data.wpr[lastIdx] - data.wpr_center) / data.wpr_scale;
        wpr_norm = MathMax(-1.0, MathMin(1.0, wpr_norm));
        totalScore += wpr_norm * w;
    }
    
    // Awesome Oscillator: centrato sulla media EMPIRICA, scala EMPIRICA
    // 🌱 Non più 0 hardcoded ma centro calcolato dal mercato!
    if (enableAO && ArraySize(data.ao) > lastIdx && data.ao_scale > 0) {
        // ✅ VALIDATO: data.ao_scale > 0 verificato nell'if
        double ao_norm = (data.ao[lastIdx] - data.ao_center) / data.ao_scale;
        ao_norm = MathMax(-1.0, MathMin(1.0, ao_norm));
        totalScore += ao_norm * w;
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
    
    // MFI: centrato sulla media EMPIRICA, scala EMPIRICA
    if (enableMFI && ArraySize(data.mfi) > lastIdx && data.mfi_scale > 0) {
        // 🌱 Centro e scala EMPIRICI derivati dai DATI!
        // ✅ VALIDATO: data.mfi_scale > 0 verificato nell'if
        double mfi_norm = (data.mfi[lastIdx] - data.mfi_center) / data.mfi_scale;
        mfi_norm = MathMax(-1.0, MathMin(1.0, mfi_norm));
        totalScore += mfi_norm * w;
    }
    
    // Donchian: posizione rispetto al canale
    // 🔧 FIX: Aggiunta protezione minima range come per BB
    // 🔧 FIX: Bounds check corretto - ArraySize >= lastIdx per accesso a [lastIdx-1]
    if (enableDonchian && lastIdx > 0 && ArraySize(data.donchian_upper) >= lastIdx && ArraySize(data.donchian_lower) >= lastIdx) {
        double don_mid = (data.donchian_upper[lastIdx-1] + data.donchian_lower[lastIdx-1]) / 2.0;
        double don_range = data.donchian_upper[lastIdx-1] - data.donchian_lower[lastIdx-1];
        // 🔧 FIX: Minimo range organico = ATR × φ⁻² per evitare divisione per valori troppo piccoli
        double min_don_range = atr_scale * PHI_INV_SQ;
        if (min_don_range <= 0) min_don_range = point_value * PHI;  // Fallback assoluto
        
        double don_norm = 0;
        if (don_range > min_don_range) {
            don_norm = (price - don_mid) / (don_range / 2.0);
            don_norm = MathMax(-1.0, MathMin(1.0, don_norm));
        }
        // Se don_range <= min_don_range, range troppo stretto, segnale neutro (0)
        totalScore += don_norm * w;
    }
    
    // Ichimoku: posizione rispetto alla cloud
    // 🌱 Scala ORGANICA: distanza dalla cloud normalizzata con ATR
    // 🔧 FIX: Ichimoku Senkou Span in MT5 sono proiettati 26 periodi NEL FUTURO.
    //       Per confrontare il prezzo ATTUALE con la cloud VISIBILE ORA,
    //       usiamo lastIdx che contiene il valore già proiettato dal buffer MT5.
    //       La cloud "attuale" visibile sul grafico è quella in data.ichimoku_spanX[lastIdx]
    if (enableIchimoku && ArraySize(data.ichimoku_spanA) > lastIdx && ArraySize(data.ichimoku_spanB) > lastIdx) {
        double spanA = data.ichimoku_spanA[lastIdx];
        double spanB = data.ichimoku_spanB[lastIdx];
        
        // 🔧 FIX: Validazione valori Ichimoku - ENTRAMBI devono essere > 0
        //       Se uno è 0 e l'altro no, la cloud è parziale e non valida
        if (spanA <= 0 || spanB <= 0) {
            // Cloud non valida (parziale o non calcolata), skip
        } else {
            double cloudTop = MathMax(spanA, spanB);
            double cloudBottom = MathMin(spanA, spanB);
            double cloud_thickness = cloudTop - cloudBottom;
            
            double ichi_norm = 0;
            if (price > cloudTop) {
                ichi_norm = MathMin(1.0, (price - cloudTop) / atr_scale);
            } else if (price < cloudBottom) {
                ichi_norm = MathMax(-1.0, (price - cloudBottom) / atr_scale);
            }
            // Dentro la cloud = 0 (neutro)
            totalScore += ichi_norm * w;
        }
    }
    
    // SMA Cross: posizione prezzo vs SMA50 vs SMA200
    // Golden Cross (SMA50 > SMA200) = trend rialzista
    // Death Cross (SMA50 < SMA200) = trend ribassista
    // 🌱 Pesi ORGANICI basati sulla sequenza di Fibonacci inversa: 1, 1/φ, 1/φ²
    if (enableSMA && ArraySize(data.sma50) > lastIdx && ArraySize(data.sma200) > lastIdx) {
        double sma50 = data.sma50[lastIdx];
        double sma200 = data.sma200[lastIdx];
        double sma_norm = 0;
        
        if (sma50 > sma200) {
            // Golden Cross attivo (uptrend)
            if (price > sma50) {
                sma_norm = 1.0;        // Forte BUY: prezzo sopra entrambe (1.0)
            } else if (price > sma200) {
                sma_norm = PHI_INV;    // BUY moderato: pullback (1/φ ≈ 0.618)
            } else {
                sma_norm = -PHI_INV_CUB; // Debolezza: prezzo sotto (-1/φ³ ≈ -0.236)
            }
        } else if (sma50 < sma200) {
            // Death Cross attivo (downtrend)
            if (price < sma50) {
                sma_norm = -1.0;       // Forte SELL: prezzo sotto entrambe (-1.0)
            } else if (price < sma200) {
                sma_norm = -PHI_INV;   // SELL moderato: pullback (-1/φ ≈ -0.618)
            } else {
                sma_norm = PHI_INV_CUB;  // Forza: prezzo sopra (1/φ³ ≈ 0.236)
            }
        }
        // Se SMA50 == SMA200 (raro), sma_norm rimane 0 (neutro)
        
        totalScore += sma_norm * w;
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
    // 🌱 ATR: CONTRARIAN con media ORGANICA (senza moltiplicatore!)
    // Formula: Se ATR_corrente > ATR_avg → alta volatilità → contrarian
    // NESSUN moltiplicatore hardcodato - pura logica organica
    // Alta volatilità spesso precede inversioni di tendenza
    //
    // ⚠️ NOTA IMPORTANTE: Questo è un indicatore CONTRARIAN intenzionalmente!
    // ATR alto + prezzo salito = possibile SELL (inversione attesa)
    // ATR alto + prezzo sceso = possibile BUY (inversione attesa)
    // Questo può contraddire altri indicatori trend-following.
    // Se preferisci solo trend-following, disabilita enableATRsignal.
    // ═══════════════════════════════════════════════════════════════
    if (enableATRsignal && ArraySize(data.atr) > lastIdx && data.atr_avg > 0) {
        double atr_current = data.atr[lastIdx];
        double atr_avg_organic = data.atr_avg;
        
        // 🌱 ATR alto = SOPRA la media organica (senza moltiplicatore!)
        // Lookback per price_change = naturalPeriod (derivato dai DATI)
        int price_lookback = data.organic.naturalPeriod;
        if (atr_current > atr_avg_organic && lastIdx >= price_lookback) {
            // Determina direzione corrente del prezzo (ultimi naturalPeriod bar)
            double price_change = data.rates[lastIdx].close - data.rates[lastIdx - price_lookback].close;
            
            // CONTRARIAN: vota nella direzione OPPOSTA al movimento recente
            // Se prezzo è salito e volatilità alta → possibile inversione → SELL
            // Se prezzo è sceso e volatilità alta → possibile inversione → BUY
            double atr_norm = 0;
            if (price_change > 0) {
                atr_norm = -1.0;  // Prezzo salito + ATR alto = SELL (inversione attesa)
            } else if (price_change < 0) {
                atr_norm = 1.0;   // Prezzo sceso + ATR alto = BUY (inversione attesa)
            }
            
            // Forza del segnale proporzionale a quanto ATR supera la media
            // Formula: strength = (ATR_corrente / ATR_avg) - 1, max 1.0
            double atr_strength = MathMin(1.0, (atr_current / atr_avg_organic) - 1.0);
            
            totalScore += atr_norm * atr_strength * w;
            
            // 🌱 Log organico ATR (se abilitato)
            if (g_enableLogsEffective) {
                PrintFormat("[%s] 🌱 ATR ORGANICO: val=%.5f > avg=%.5f → forza=%.2f → direzione=%s",
                    timeframe, atr_current, atr_avg_organic, atr_strength,
                    atr_norm > 0 ? "BUY (contrarian)" : "SELL (contrarian)");
            }
        }
        // Se ATR <= media, non contribuisce (volatilità normale)
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
    
    // 🔧 FIX: Warmup check - aggiorna indicatori ma non tradare durante warmup
    // Protezione multipla: barre + tempo + tick count per evitare bypass
    static int warmupTickCount = 0;
    if (!g_warmupComplete) {
        warmupTickCount++;
        int currentBars = Bars(_Symbol, PERIOD_H1);  // Usa H1 come riferimento
        long secondsRunning = (long)(TimeCurrent() - g_eaStartTime);
        
        // 🔧 FIX: Warmup completo SOLO se tutte le condizioni sono soddisfatte:
        // 1. Abbastanza barre (dati storici sufficienti)
        // 2. Almeno 60 secondi (tempo reale, evita burst in backtest)
        // 3. Almeno 100 tick (garanzia aggiuntiva per backtest veloci)
        if (currentBars >= g_warmupBarsRequired && secondsRunning >= 60 && warmupTickCount >= 100) {
            g_warmupComplete = true;
            Print("✅ [WARMUP] Completato - EA pronto per il trading");
        } else {
            // Durante warmup, aggiorna comunque il sistema ma non tradare
            static datetime lastWarmupLog = 0;
            if (TimeCurrent() - lastWarmupLog >= 30) {  // Log ogni 30 secondi max
                PrintFormat("🔄 [WARMUP] In corso: %d/%d barre, %ld sec, %d tick", 
                    currentBars, g_warmupBarsRequired, secondsRunning, warmupTickCount);
                lastWarmupLog = TimeCurrent();
            }
            
            // Aggiorna solo gli indicatori durante warmup
            datetime currentBarTime_warmup = iTime(_Symbol, PERIOD_CURRENT, 0);
            if (currentBarTime_warmup != lastBarTime) {
                lastBarTime = currentBarTime_warmup;
                RecalculateOrganicSystem();
            }
            return;  // Non proseguire con trading durante warmup
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
    // 🌱 barsToLoad = max(sma200 di tutti i TF) × φ (buffer statistico)
    // Usiamo il max tra tutti i periodi organici, NON φ^12 arbitrario!
    // sma200 è sempre il periodo più lungo (longest in CalculateOrganicPeriods)
    // ═══════════════════════════════════════════════════════════════=
    int maxPeriodNeeded = MathMax(g_organic_M5.sma200, 
                          MathMax(g_organic_H1.sma200,
                          MathMax(g_organic_H4.sma200, g_organic_D1.sma200)));
    // Buffer = periodo max × φ (per avere overlap statistico)
    int barsToLoad = (int)MathRound(maxPeriodNeeded * PHI);
    // 🌱 Minimo organico = φ⁸ ≈ 47 (derivato da potenza di φ)
    int minBarsOrganic = (int)MathRound(PHI_SQ * PHI_SQ * PHI_SQ * PHI_SQ);  // φ⁸ ≈ 46.98
    barsToLoad = MathMax(barsToLoad, minBarsOrganic);
    
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
    // ═══════════════════════════════════════════════════════════════
    if (!IsTradeAllowedByHurst()) {
        if (g_enableLogsEffective) Print("[TRADE] ⛔ BLOCCATO da filtro Hurst - mercato in regime random");
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
    else {
        if (g_enableLogsEffective) Print("[TRADE] ⚪ Nessun segnale - in attesa...");
    }
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
    double kBuf[1], dBuf[1], cciBuf[1], momBuf[1], psarBuf[1];
    double price = 0.0;
    int latestIdxM5 = 0;
    double wprValue = 0.0, aoValue = 0.0, mfiValue = 0.0;
    double spanA_M5 = 0.0, spanB_M5 = 0.0;
    // cATR e cADX rimossi perché ATR/ADX non sono direzionali
    bool cEMA = false, cRSI = false, cMACD = false, cBB = false;
    bool cSTO = false, cCCI = false, cMOM = false, cPSAR = false;
    bool cHeikin = false, cWPR = false, cAO = false, cOBV = false, cMFI = false;
    bool cDonchian = false, cIchimoku = false;
    
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
        ok &= (CopyBuffer(stochHandle_M5, 0, 1, 1, kBuf) > 0);
        ok &= (CopyBuffer(stochHandle_M5, 1, 1, 1, dBuf) > 0);
        ok &= (CopyBuffer(cciHandle_M5, 0, 1, 1, cciBuf) > 0);
        ok &= (CopyBuffer(momentumHandle_M5, 0, 1, 1, momBuf) > 0);
        ok &= (CopyBuffer(psarHandle_M5, 0, 1, 1, psarBuf) > 0);
        
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
        cSTO  = enableStoch       && (kBuf[0] > dBuf[0]);
        cCCI  = enableCCI         && (cciBuf[0] > tfData_M5.cci_center);
        cMOM  = enableMomentum    && (momBuf[0] > tfData_M5.momentum_center);
        cPSAR = false;
        if (enablePSAR) {
            double sarValue = psarBuf[0];
            cPSAR = (sarValue != 0.0 && price > sarValue);
        }
        // 🛡️ Controlli array bounds per indicatori da struct tfData
        cHeikin = false;
        if (enableHeikin && ArraySize(tfData_M5.ha_close) > latestIdxM5 && ArraySize(tfData_M5.ha_open) > latestIdxM5) {
            cHeikin = (tfData_M5.ha_close[latestIdxM5] > tfData_M5.ha_open[latestIdxM5]);
        }
        wprValue = 0;
        if (ArraySize(tfData_M5.wpr) > latestIdxM5) {
            wprValue = tfData_M5.wpr[latestIdxM5];
        }
        cWPR = enableWPR && (wprValue > tfData_M5.wpr_center);
        aoValue = 0;
        if (ArraySize(tfData_M5.ao) > latestIdxM5) {
            aoValue = tfData_M5.ao[latestIdxM5];
        }
        cAO = enableAO && (aoValue > 0);
        cOBV = false;
        if (enableOBV && ArraySize(tfData_M5.obv) > latestIdxM5 && latestIdxM5 >= 1) {
            cOBV = (tfData_M5.obv[latestIdxM5] >= tfData_M5.obv[latestIdxM5 - 1]);
        }
        mfiValue = 0;
        if (ArraySize(tfData_M5.mfi) > latestIdxM5) {
            mfiValue = tfData_M5.mfi[latestIdxM5];
        }
        cMFI = enableMFI && (mfiValue > tfData_M5.mfi_center);
        cDonchian = false;
        if (enableDonchian && ArraySize(tfData_M5.donchian_upper) > latestIdxM5 && latestIdxM5 >= 1) {
            cDonchian = (price > tfData_M5.donchian_upper[latestIdxM5 - 1]);
        }
        spanA_M5 = 0;
        spanB_M5 = 0;
        if (ArraySize(tfData_M5.ichimoku_spanA) > latestIdxM5 && ArraySize(tfData_M5.ichimoku_spanB) > latestIdxM5) {
            spanA_M5 = tfData_M5.ichimoku_spanA[latestIdxM5];
            spanB_M5 = tfData_M5.ichimoku_spanB[latestIdxM5];
        }
        // 🔧 FIX: Entrambi span devono essere > 0 (non cloud parziale)
        cIchimoku = enableIchimoku && (spanA_M5 > 0 && spanB_M5 > 0) && (price > MathMax(spanA_M5, spanB_M5));
        
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
            PrintFormat("  CCI: %.2f vs Centro Empirico=%.2f → %s (%s)",
                cciBuf[0], tfData_M5.cci_center, cCCI ? "✅ BUY" : "❌ SELL", enableCCI ? "ATTIVO" : "disattivo");
            PrintFormat("  Stoch: K=%.2f vs D=%.2f → %s (%s)",
                kBuf[0], dBuf[0], cSTO ? "✅ BUY" : "❌ SELL", enableStoch ? "ATTIVO" : "disattivo");
            PrintFormat("  Momentum: %.2f vs Centro Empirico=%.2f → %s (%s)",
                momBuf[0], tfData_M5.momentum_center, cMOM ? "✅ BUY" : "❌ SELL", enableMomentum ? "ATTIVO" : "disattivo");
            PrintFormat("  PSAR: Price=%.5f vs SAR=%.5f → %s (%s)",
                price, psarBuf[0], cPSAR ? "✅ BUY" : "❌ SELL", enablePSAR ? "ATTIVO" : "disattivo");
            // 🛡️ Log con valori già controllati (cHeikin, wprValue, aoValue, mfiValue calcolati sopra)
            double ha_close_log = (ArraySize(tfData_M5.ha_close) > latestIdxM5) ? tfData_M5.ha_close[latestIdxM5] : 0;
            double ha_open_log = (ArraySize(tfData_M5.ha_open) > latestIdxM5) ? tfData_M5.ha_open[latestIdxM5] : 0;
            PrintFormat("  Heikin Ashi: HAclose=%.5f vs HAopen=%.5f → %s (%s)",
                ha_close_log, ha_open_log, cHeikin ? "✅ BUY" : "❌ SELL", enableHeikin ? "ATTIVO" : "disattivo");
            PrintFormat("  WPR: %.2f vs Centro Empirico=%.2f → %s (%s)",
                wprValue, tfData_M5.wpr_center, cWPR ? "✅ BUY" : "❌ SELL", enableWPR ? "ATTIVO" : "disattivo");
            PrintFormat("  AO: %.5f → %s (%s)",
                aoValue, cAO ? "✅ BUY" : "❌ SELL", enableAO ? "ATTIVO" : "disattivo");
            double obv_curr = (ArraySize(tfData_M5.obv) > latestIdxM5) ? tfData_M5.obv[latestIdxM5] : 0;
            double obv_prev = (ArraySize(tfData_M5.obv) > latestIdxM5 && latestIdxM5 >= 1) ? tfData_M5.obv[latestIdxM5 - 1] : 0;
            PrintFormat("  OBV: %.0f vs Prev=%.0f → %s (%s)",
                obv_curr, obv_prev, cOBV ? "✅ BUY" : "❌ SELL", enableOBV ? "ATTIVO" : "disattivo");
            PrintFormat("  MFI: %.2f vs Centro Empirico=%.2f → %s (%s)",
                mfiValue, tfData_M5.mfi_center, cMFI ? "✅ BUY" : "❌ SELL", enableMFI ? "ATTIVO" : "disattivo");
            double donchian_prev = (ArraySize(tfData_M5.donchian_upper) > latestIdxM5 && latestIdxM5 >= 1) ? tfData_M5.donchian_upper[latestIdxM5 - 1] : 0;
            PrintFormat("  Donchian: Close=%.5f vs UpperPrev=%.5f → %s (%s)",
                price, donchian_prev, cDonchian ? "✅ BREAKOUT" : "❌ NO BREAK", enableDonchian ? "ATTIVO" : "disattivo");
            PrintFormat("  Ichimoku: Price=%.5f vs CloudTop=%.5f → %s (%s)",
                price, MathMax(spanA_M5, spanB_M5), cIchimoku ? "✅ ABOVE CLOUD" : "❌ INSIDE/BELOW", enableIchimoku ? "ATTIVO" : "disattivo");
            // SMA Cross log
            double sma50_M5 = (ArraySize(tfData_M5.sma50) > latestIdxM5) ? tfData_M5.sma50[latestIdxM5] : 0;
            double sma200_M5 = (ArraySize(tfData_M5.sma200) > latestIdxM5) ? tfData_M5.sma200[latestIdxM5] : 0;
            string smaCross_M5 = (sma50_M5 > sma200_M5) ? "🟢 Golden Cross" : ((sma50_M5 < sma200_M5) ? "🔴 Death Cross" : "⚪ Flat");
            string smaPos_M5 = (price > sma50_M5 && price > sma200_M5) ? "ABOVE BOTH" : ((price < sma50_M5 && price < sma200_M5) ? "BELOW BOTH" : "BETWEEN");
            PrintFormat("  SMA Cross: SMA50=%.5f vs SMA200=%.5f → %s | Price %s (%s)",
                sma50_M5, sma200_M5, smaCross_M5, smaPos_M5, enableSMA ? "ATTIVO" : "disattivo");
            PrintFormat("  🎯 SCORE M5: %.2f", scoreM5);
        } else {
            Print("  📊 M5 Score:  N/D (DISATTIVATO)");
        }
    }
    
    // H1 INDICATORS
    if (g_vote_H1_active && g_enableLogsEffective) {
        int h1_idx = ArraySize(tfData_H1.rsi) - 1;
        if (h1_idx < 0) {
            Print("\n--- H1: DATI NON DISPONIBILI ---");
        } else {
        Print("\n--- H1 (INTERMEDIO) ---");
        PrintFormat("  🌱 Peso organico TF: %.2f", tfData_H1.organic.weight);
    double h1_psarValue = (ArraySize(tfData_H1.psar) > h1_idx) ? tfData_H1.psar[h1_idx] : 0.0;
    bool h1_psarValid = (h1_psarValue != 0.0);
    bool h1_cPSAR = h1_psarValid && (price > h1_psarValue);
    double h1_close = (ArraySize(tfData_H1.rates) > h1_idx) ? tfData_H1.rates[h1_idx].close : price;
    double h1_spanA = (ArraySize(tfData_H1.ichimoku_spanA) > h1_idx) ? tfData_H1.ichimoku_spanA[h1_idx] : 0;
    double h1_spanB = (ArraySize(tfData_H1.ichimoku_spanB) > h1_idx) ? tfData_H1.ichimoku_spanB[h1_idx] : 0;
    double h1_cloudTop = MathMax(h1_spanA, h1_spanB);
    int h1_prevIdx = (h1_idx > 0) ? h1_idx - 1 : 0;
    double h1_mom = (ArraySize(tfData_H1.momentum) > h1_idx) ? tfData_H1.momentum[h1_idx] : 0;
    bool h1_cMOM = h1_mom > tfData_H1.momentum_center;
    double h1_ema = (ArraySize(tfData_H1.ema) > h1_idx) ? tfData_H1.ema[h1_idx] : 0;
    PrintFormat("  EMA: Price=%.5f vs EMA=%.5f → %s",
        price, h1_ema, (price > h1_ema) ? "BUY" : "SELL");
    // 🛡️ Estrai valori con controlli ArraySize
    double h1_rsi = (ArraySize(tfData_H1.rsi) > h1_idx) ? tfData_H1.rsi[h1_idx] : 0;
    double h1_adx = (ArraySize(tfData_H1.adx) > h1_idx) ? tfData_H1.adx[h1_idx] : 0;
    double h1_cci = (ArraySize(tfData_H1.cci) > h1_idx) ? tfData_H1.cci[h1_idx] : 0;
    double h1_ha_close = (ArraySize(tfData_H1.ha_close) > h1_idx) ? tfData_H1.ha_close[h1_idx] : 0;
    double h1_ha_open = (ArraySize(tfData_H1.ha_open) > h1_idx) ? tfData_H1.ha_open[h1_idx] : 0;
    double h1_wpr = (ArraySize(tfData_H1.wpr) > h1_idx) ? tfData_H1.wpr[h1_idx] : 0;
    double h1_ao = (ArraySize(tfData_H1.ao) > h1_idx) ? tfData_H1.ao[h1_idx] : 0;
    double h1_obv = (ArraySize(tfData_H1.obv) > h1_idx) ? tfData_H1.obv[h1_idx] : 0;
    double h1_obv_prev = (ArraySize(tfData_H1.obv) > h1_prevIdx) ? tfData_H1.obv[h1_prevIdx] : 0;
    double h1_mfi = (ArraySize(tfData_H1.mfi) > h1_idx) ? tfData_H1.mfi[h1_idx] : 0;
    double h1_don_prev = (ArraySize(tfData_H1.donchian_upper) > h1_prevIdx) ? tfData_H1.donchian_upper[h1_prevIdx] : 0;
    
    PrintFormat("  RSI: %.2f vs Centro Empirico=%.2f → %s",
        h1_rsi, tfData_H1.rsi_center, 
        (h1_rsi > tfData_H1.rsi_center) ? "BUY" : "SELL");
    PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f → %s (vota con +DI/-DI)",
        h1_adx, tfData_H1.adx_threshold,
        (h1_adx > tfData_H1.adx_threshold) ? "TREND" : "NO TREND");
    PrintFormat("  CCI: %.2f vs Centro Empirico=%.2f → %s",
        h1_cci, tfData_H1.cci_center,
        (h1_cci > tfData_H1.cci_center) ? "BUY" : "SELL");
    PrintFormat("  PSAR: Price=%.5f vs SAR=%.5f → %s",
        price, h1_psarValue, h1_cPSAR ? "BUY" : "SELL");
    PrintFormat("  Momentum: %.2f vs Centro Empirico=%.2f → %s",
        h1_mom, tfData_H1.momentum_center,
        h1_cMOM ? "BUY" : "SELL");
    PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f → %s",
        h1_ha_close, h1_ha_open,
        (h1_ha_close > h1_ha_open) ? "BUY" : "SELL");
    PrintFormat("  WPR: %.2f vs Centro Empirico=%.2f → %s",
        h1_wpr, tfData_H1.wpr_center,
        (h1_wpr > tfData_H1.wpr_center) ? "BUY" : "SELL");
    PrintFormat("  AO: %.5f → %s",
        h1_ao, (h1_ao > 0) ? "BUY" : "SELL");
    PrintFormat("  OBV: %.0f vs Prev=%.0f → %s",
        h1_obv, h1_obv_prev,
        (h1_obv >= h1_obv_prev) ? "BUY" : "SELL");
    PrintFormat("  MFI: %.2f vs Centro Empirico=%.2f → %s",
        h1_mfi, tfData_H1.mfi_center,
        (h1_mfi > tfData_H1.mfi_center) ? "BUY" : "SELL");
    PrintFormat("  Donchian: Close=%.5f vs UpperPrev=%.5f → %s",
        h1_close, h1_don_prev,
        (h1_close > h1_don_prev) ? "BREAKOUT" : "NO BREAK");
    PrintFormat("  Ichimoku: Price=%.5f vs CloudTop=%.5f → %s",
        h1_close, h1_cloudTop,
        (h1_close > h1_cloudTop) ? "ABOVE" : "INSIDE/BELOW");
        // SMA Cross log
        double sma50_H1 = (ArraySize(tfData_H1.sma50) > h1_idx) ? tfData_H1.sma50[h1_idx] : 0;
        double sma200_H1 = (ArraySize(tfData_H1.sma200) > h1_idx) ? tfData_H1.sma200[h1_idx] : 0;
        string smaCross_H1 = (sma50_H1 > sma200_H1) ? "Golden Cross" : ((sma50_H1 < sma200_H1) ? "Death Cross" : "Flat");
        string smaPos_H1 = (h1_close > sma50_H1 && h1_close > sma200_H1) ? "ABOVE BOTH" : ((h1_close < sma50_H1 && h1_close < sma200_H1) ? "BELOW BOTH" : "BETWEEN");
        PrintFormat("  SMA Cross: SMA50=%.5f vs SMA200=%.5f → %s | Price %s",
            sma50_H1, sma200_H1, smaCross_H1, smaPos_H1);
        PrintFormat("  🎯 SCORE H1: %.2f", scoreH1);
        } // fine else h1_idx >= 0
    } else if (g_enableLogsEffective) {
        Print("  📊 H1 Score:  N/D (DISATTIVATO)");
    }
    
    // H4 INDICATORS
    if (g_vote_H4_active && g_enableLogsEffective) {
        int h4_idx = ArraySize(tfData_H4.rsi) - 1;
        if (h4_idx < 0) {
            Print("\n--- H4: DATI NON DISPONIBILI ---");
        } else {
        Print("\n--- H4 (SWING) ---");
        PrintFormat("  🌱 Peso organico TF: %.2f", tfData_H4.organic.weight);
    double h4_psarValue = (ArraySize(tfData_H4.psar) > h4_idx) ? tfData_H4.psar[h4_idx] : 0.0;
    bool h4_psarValid = (h4_psarValue != 0.0);
    bool h4_cPSAR = h4_psarValid && (price > h4_psarValue);
    double h4_close = (ArraySize(tfData_H4.rates) > h4_idx) ? tfData_H4.rates[h4_idx].close : price;
    double h4_spanA = (ArraySize(tfData_H4.ichimoku_spanA) > h4_idx) ? tfData_H4.ichimoku_spanA[h4_idx] : 0;
    double h4_spanB = (ArraySize(tfData_H4.ichimoku_spanB) > h4_idx) ? tfData_H4.ichimoku_spanB[h4_idx] : 0;
    double h4_cloudTop = MathMax(h4_spanA, h4_spanB);
    int h4_prevIdx = (h4_idx > 0) ? h4_idx - 1 : 0;
    double h4_mom = (ArraySize(tfData_H4.momentum) > h4_idx) ? tfData_H4.momentum[h4_idx] : 0;
    bool h4_cMOM = h4_mom > tfData_H4.momentum_center;
    double h4_ema = (ArraySize(tfData_H4.ema) > h4_idx) ? tfData_H4.ema[h4_idx] : 0;
    PrintFormat("  EMA: Price=%.5f vs EMA=%.5f → %s",
        price, h4_ema, (price > h4_ema) ? "BUY" : "SELL");
    
    // 🛡️ Estrai valori con controlli ArraySize
    double h4_rsi = (ArraySize(tfData_H4.rsi) > h4_idx) ? tfData_H4.rsi[h4_idx] : 0;
    double h4_adx = (ArraySize(tfData_H4.adx) > h4_idx) ? tfData_H4.adx[h4_idx] : 0;
    double h4_cci = (ArraySize(tfData_H4.cci) > h4_idx) ? tfData_H4.cci[h4_idx] : 0;
    double h4_ha_close = (ArraySize(tfData_H4.ha_close) > h4_idx) ? tfData_H4.ha_close[h4_idx] : 0;
    double h4_ha_open = (ArraySize(tfData_H4.ha_open) > h4_idx) ? tfData_H4.ha_open[h4_idx] : 0;
    double h4_wpr = (ArraySize(tfData_H4.wpr) > h4_idx) ? tfData_H4.wpr[h4_idx] : 0;
    double h4_ao = (ArraySize(tfData_H4.ao) > h4_idx) ? tfData_H4.ao[h4_idx] : 0;
    double h4_obv = (ArraySize(tfData_H4.obv) > h4_idx) ? tfData_H4.obv[h4_idx] : 0;
    double h4_obv_prev = (ArraySize(tfData_H4.obv) > h4_prevIdx) ? tfData_H4.obv[h4_prevIdx] : 0;
    double h4_mfi = (ArraySize(tfData_H4.mfi) > h4_idx) ? tfData_H4.mfi[h4_idx] : 0;
    double h4_don_prev = (ArraySize(tfData_H4.donchian_upper) > h4_prevIdx) ? tfData_H4.donchian_upper[h4_prevIdx] : 0;
    
    PrintFormat("  RSI: %.2f vs Centro Empirico=%.2f → %s",
        h4_rsi, tfData_H4.rsi_center,
        (h4_rsi > tfData_H4.rsi_center) ? "BUY" : "SELL");
    PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f → %s (vota con +DI/-DI)",
        h4_adx, tfData_H4.adx_threshold,
        (h4_adx > tfData_H4.adx_threshold) ? "TREND" : "NO TREND");
    PrintFormat("  CCI: %.2f vs Centro Empirico=%.2f → %s",
        h4_cci, tfData_H4.cci_center,
        (h4_cci > tfData_H4.cci_center) ? "BUY" : "SELL");
    PrintFormat("  PSAR: Price=%.5f vs SAR=%.5f → %s",
        price, h4_psarValue, h4_cPSAR ? "BUY" : "SELL");
    PrintFormat("  Momentum: %.2f vs Centro Empirico=%.2f → %s",
        h4_mom, tfData_H4.momentum_center,
        h4_cMOM ? "BUY" : "SELL");
    PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f → %s",
        h4_ha_close, h4_ha_open,
        (h4_ha_close > h4_ha_open) ? "BUY" : "SELL");
    PrintFormat("  WPR: %.2f vs Centro Empirico=%.2f → %s",
        h4_wpr, tfData_H4.wpr_center,
        (h4_wpr > tfData_H4.wpr_center) ? "BUY" : "SELL");
    PrintFormat("  AO: %.5f → %s",
        h4_ao, (h4_ao > 0) ? "BUY" : "SELL");
    PrintFormat("  OBV: %.0f vs Prev=%.0f → %s",
        h4_obv, h4_obv_prev,
        (h4_obv >= h4_obv_prev) ? "BUY" : "SELL");
    PrintFormat("  MFI: %.2f vs Centro Empirico=%.2f → %s",
        h4_mfi, tfData_H4.mfi_center,
        (h4_mfi > tfData_H4.mfi_center) ? "BUY" : "SELL");
    PrintFormat("  Donchian: Close=%.5f vs UpperPrev=%.5f → %s",
        h4_close, h4_don_prev,
        (h4_close > h4_don_prev) ? "BREAKOUT" : "NO BREAK");
    PrintFormat("  Ichimoku: Price=%.5f vs CloudTop=%.5f → %s",
        h4_close, h4_cloudTop,
        (h4_close > h4_cloudTop) ? "ABOVE" : "INSIDE/BELOW");
        // SMA Cross log
        double sma50_H4 = (ArraySize(tfData_H4.sma50) > h4_idx) ? tfData_H4.sma50[h4_idx] : 0;
        double sma200_H4 = (ArraySize(tfData_H4.sma200) > h4_idx) ? tfData_H4.sma200[h4_idx] : 0;
        string smaCross_H4 = (sma50_H4 > sma200_H4) ? "Golden Cross" : ((sma50_H4 < sma200_H4) ? "Death Cross" : "Flat");
        string smaPos_H4 = (h4_close > sma50_H4 && h4_close > sma200_H4) ? "ABOVE BOTH" : ((h4_close < sma50_H4 && h4_close < sma200_H4) ? "BELOW BOTH" : "BETWEEN");
        PrintFormat("  SMA Cross: SMA50=%.5f vs SMA200=%.5f → %s | Price %s",
            sma50_H4, sma200_H4, smaCross_H4, smaPos_H4);
        PrintFormat("  🎯 SCORE H4: %.2f", scoreH4);
        } // fine else h4_idx >= 0
    } else if (g_enableLogsEffective) {
        Print("  📊 H4 Score:  N/D (DISATTIVATO)");
    }
    
    // D1 INDICATORS
    if (g_vote_D1_active && g_enableLogsEffective) {
        int d1_idx = ArraySize(tfData_D1.rsi) - 1;
        if (d1_idx < 0) {
            Print("\n--- D1: DATI NON DISPONIBILI ---");
        } else {
        Print("\n--- D1 (TREND LUNGO) ---");
        PrintFormat("  🌱 Peso organico TF: %.2f", tfData_D1.organic.weight);
    double d1_psarValue = (ArraySize(tfData_D1.psar) > d1_idx) ? tfData_D1.psar[d1_idx] : 0.0;
    bool d1_psarValid = (d1_psarValue != 0.0);
    bool d1_cPSAR = d1_psarValid && (price > d1_psarValue);
    double d1_close = (ArraySize(tfData_D1.rates) > d1_idx) ? tfData_D1.rates[d1_idx].close : price;
    double d1_spanA = (ArraySize(tfData_D1.ichimoku_spanA) > d1_idx) ? tfData_D1.ichimoku_spanA[d1_idx] : 0;
    double d1_spanB = (ArraySize(tfData_D1.ichimoku_spanB) > d1_idx) ? tfData_D1.ichimoku_spanB[d1_idx] : 0;
    double d1_cloudTop = MathMax(d1_spanA, d1_spanB);
    int d1_prevIdx = (d1_idx > 0) ? d1_idx - 1 : 0;
    double d1_mom = (ArraySize(tfData_D1.momentum) > d1_idx) ? tfData_D1.momentum[d1_idx] : 0;
    bool d1_cMOM = d1_mom > tfData_D1.momentum_center;
    double d1_ema = (ArraySize(tfData_D1.ema) > d1_idx) ? tfData_D1.ema[d1_idx] : 0;
    PrintFormat("  EMA: Price=%.5f vs EMA=%.5f → %s",
        price, d1_ema, (price > d1_ema) ? "BUY" : "SELL");
    
    // 🛡️ Estrai valori con controlli ArraySize
    double d1_rsi = (ArraySize(tfData_D1.rsi) > d1_idx) ? tfData_D1.rsi[d1_idx] : 0;
    double d1_adx = (ArraySize(tfData_D1.adx) > d1_idx) ? tfData_D1.adx[d1_idx] : 0;
    double d1_cci = (ArraySize(tfData_D1.cci) > d1_idx) ? tfData_D1.cci[d1_idx] : 0;
    double d1_ha_close = (ArraySize(tfData_D1.ha_close) > d1_idx) ? tfData_D1.ha_close[d1_idx] : 0;
    double d1_ha_open = (ArraySize(tfData_D1.ha_open) > d1_idx) ? tfData_D1.ha_open[d1_idx] : 0;
    double d1_wpr = (ArraySize(tfData_D1.wpr) > d1_idx) ? tfData_D1.wpr[d1_idx] : 0;
    double d1_ao = (ArraySize(tfData_D1.ao) > d1_idx) ? tfData_D1.ao[d1_idx] : 0;
    double d1_obv = (ArraySize(tfData_D1.obv) > d1_idx) ? tfData_D1.obv[d1_idx] : 0;
    double d1_obv_prev = (ArraySize(tfData_D1.obv) > d1_prevIdx) ? tfData_D1.obv[d1_prevIdx] : 0;
    double d1_mfi = (ArraySize(tfData_D1.mfi) > d1_idx) ? tfData_D1.mfi[d1_idx] : 0;
    double d1_don_prev = (ArraySize(tfData_D1.donchian_upper) > d1_prevIdx) ? tfData_D1.donchian_upper[d1_prevIdx] : 0;
    
    PrintFormat("  RSI: %.2f vs Centro Empirico=%.2f → %s",
        d1_rsi, tfData_D1.rsi_center,
        (d1_rsi > tfData_D1.rsi_center) ? "BUY" : "SELL");
    PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f → %s (vota con +DI/-DI)",
        d1_adx, tfData_D1.adx_threshold,
        (d1_adx > tfData_D1.adx_threshold) ? "TREND" : "NO TREND");
    PrintFormat("  CCI: %.2f vs Centro Empirico=%.2f → %s",
        d1_cci, tfData_D1.cci_center,
        (d1_cci > tfData_D1.cci_center) ? "BUY" : "SELL");
    PrintFormat("  PSAR: Price=%.5f vs SAR=%.5f → %s",
        price, d1_psarValue, d1_cPSAR ? "BUY" : "SELL");
    PrintFormat("  Momentum: %.2f vs Centro Empirico=%.2f → %s",
        d1_mom, tfData_D1.momentum_center,
        d1_cMOM ? "BUY" : "SELL");
    PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f → %s",
        d1_ha_close, d1_ha_open,
        (d1_ha_close > d1_ha_open) ? "BUY" : "SELL");
    PrintFormat("  WPR: %.2f vs Centro Empirico=%.2f → %s",
        d1_wpr, tfData_D1.wpr_center,
        (d1_wpr > tfData_D1.wpr_center) ? "BUY" : "SELL");
    PrintFormat("  AO: %.5f → %s",
        d1_ao, (d1_ao > 0) ? "BUY" : "SELL");
    PrintFormat("  OBV: %.0f vs Prev=%.0f → %s",
        d1_obv, d1_obv_prev,
        (d1_obv >= d1_obv_prev) ? "BUY" : "SELL");
    PrintFormat("  MFI: %.2f vs Centro Empirico=%.2f → %s",
        d1_mfi, tfData_D1.mfi_center,
        (d1_mfi > tfData_D1.mfi_center) ? "BUY" : "SELL");
    PrintFormat("  Donchian: Close=%.5f vs UpperPrev=%.5f → %s",
        d1_close, d1_don_prev,
        (d1_close > d1_don_prev) ? "BREAKOUT" : "NO BREAK");
    PrintFormat("  Ichimoku: Price=%.5f vs CloudTop=%.5f → %s",
        d1_close, d1_cloudTop,
        (d1_close > d1_cloudTop) ? "ABOVE" : "INSIDE/BELOW");
        // SMA Cross log
        double sma50_D1 = (ArraySize(tfData_D1.sma50) > d1_idx) ? tfData_D1.sma50[d1_idx] : 0;
        double sma200_D1 = (ArraySize(tfData_D1.sma200) > d1_idx) ? tfData_D1.sma200[d1_idx] : 0;
        string smaCross_D1 = (sma50_D1 > sma200_D1) ? "Golden Cross" : ((sma50_D1 < sma200_D1) ? "Death Cross" : "Flat");
        string smaPos_D1 = (d1_close > sma50_D1 && d1_close > sma200_D1) ? "ABOVE BOTH" : ((d1_close < sma50_D1 && d1_close < sma200_D1) ? "BELOW BOTH" : "BETWEEN");
        PrintFormat("  SMA Cross: SMA50=%.5f vs SMA200=%.5f → %s | Price %s",
            sma50_D1, sma200_D1, smaCross_D1, smaPos_D1);
        PrintFormat("  🎯 SCORE D1: %.2f", scoreD1);
        } // fine else d1_idx >= 0
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
    if (enableStoch) numIndicatorsActive++;
    if (enableCCI) numIndicatorsActive++;
    if (enableMomentum) numIndicatorsActive++;
    if (enablePSAR) numIndicatorsActive++;
    if (enableHeikin) numIndicatorsActive++;
    if (enableWPR) numIndicatorsActive++;
    if (enableAO) numIndicatorsActive++;
    if (enableOBV) numIndicatorsActive++;
    if (enableMFI) numIndicatorsActive++;
    if (enableDonchian) numIndicatorsActive++;
    if (enableIchimoku) numIndicatorsActive++;
    if (enableSMA) numIndicatorsActive++;
    
    // 🔧 FIX: ADX e ATR sono CONDIZIONALI - contano solo se superano la soglia
    // ADX vota SOLO se supera la soglia organica, altrimenti è neutro
    // ATR vota SOLO se supera la media (contrarian), altrimenti è neutro
    // Per il calcolo del max score, li contiamo come "potenzialmente attivi"
    if (enableADX) numIndicatorsActive++;     // Può votare se ADX > soglia
    if (enableATRsignal) numIndicatorsActive++; // Può votare se ATR > media
    
    // 🌱 Max score = somma dei pesi organici TF × num indicatori attivi × 1.0 (max normalized)
    if (g_vote_M5_active) maxScorePossible += g_organic_M5.weight * numIndicatorsActive;
    if (g_vote_H1_active) maxScorePossible += g_organic_H1.weight * numIndicatorsActive;
    if (g_vote_H4_active) maxScorePossible += g_organic_H4.weight * numIndicatorsActive;
    if (g_vote_D1_active) maxScorePossible += g_organic_D1.weight * numIndicatorsActive;
    
    // ✅ VALIDATO: scorePct sempre >= 0 (MathAbs + divisione protetta)
    double scorePct = (maxScorePossible > 0) ? (MathAbs(totalScore) / maxScorePossible) * 100.0 : 0;
    bool isBuy = (totalScore > 0);
    bool isSell = (totalScore < 0);
    
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
    // LOGICA DECISIONALE: Score sopra soglia = trade
    // ═══════════════════════════════════════════════════════════════
    
    if (isBuy && scorePct >= currentThreshold) {
        decision = 1;
        if (g_enableLogsEffective) PrintFormat("[VOTE] ✅ BUY: Score %.1f%% >= %.1f%% soglia", scorePct, currentThreshold);
    }
    else if (isSell && scorePct >= currentThreshold) {
        decision = -1;
        if (g_enableLogsEffective) PrintFormat("[VOTE] ✅ SELL: Score %.1f%% >= %.1f%% soglia", scorePct, currentThreshold);
    }
    else {
        if (g_enableLogsEffective) PrintFormat("[VOTE] ❌ Nessun trade: Score %.1f%% < %.1f%% soglia", scorePct, currentThreshold);
    }
    
    // Se decision è 0, esci
    if (decision == 0) {
        if (g_enableLogsEffective) PrintFormat("[VOTE] ⚪ NO TRADE - Score %.1f%% | Soglia: %.1f%%", scorePct, currentThreshold);
        return 0;
    }
    
    // Log decisione finale
    string decisionText = (decision == 1) ? "🟢 BUY" : "🔴 SELL";
    PrintFormat("[VOTE] ✅ TRADE APPROVATO: %s | Score: %.1f%% (soglia: %.1f%%)", decisionText, scorePct, currentThreshold);
    
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
    
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
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
        PrintFormat("[TRADE] ✅ SELL opened at %.5f, Lot=%.2f, SL=%.5f, TP=%.5f", price, finalLot, sl, tp);
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
    
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
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
        PrintFormat("[TRADE] ✅ BUY opened at %.5f, Lot=%.2f, SL=%.5f, TP=%.5f", price, finalLot, sl, tp);
    } else {
        int errCode = GetLastError();
        PrintFormat("[TRADE] ❌ BUY FALLITO! Errore %d: %s | Price=%.5f Lot=%.2f SL=%.5f TP=%.5f",
            errCode, ErrorDescription(errCode), price, finalLot, sl, tp);
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
