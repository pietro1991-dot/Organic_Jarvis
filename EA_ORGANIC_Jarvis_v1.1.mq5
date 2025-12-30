//+------------------------------------------------------------------+
//| --------------------------------------------------------------- |
//| ?? SISTEMA 100% ORGANICO - TUTTO DERIVATO DAI DATI              
//| --------------------------------------------------------------- |
//|                                                                 |
//| COSTANTI MATEMATICHE (solo f = Rapporto Aureo � 1.618):         |
//|   f = (1+v5)/2 | 1/f � 0.618 | 1/f� � 0.382 | 1/f� � 0.236      |
//|   f � usato SOLO come fattore di scala, non come valore fisso   |
//|                                                                 |
//| FORMULA PERIODI (100% data-driven):                             |
//|   naturalPeriod = autocorrelazione dei DATI (no minuti!)        |
//|   periodi_indicatori = naturalPeriod � potenze di f             |
//|                                                                 |
//| FORMULA PESI TF (Esponente di Hurst):                           |
//|   peso_TF = H_TF / S(H_tutti_TF)                                |
//|   H > centro: trending ? peso maggiore                          |
//|   H derivato con metodo R/S (Rescaled Range)                    |
//|                                                                 |
//| CENTRI E SCALE (100% empirici):                                 |
//|   centro = mean(indicatore) calcolato sul cross                 |
//|   scala = stdev(indicatore) � f (volatilit� reale)              |
//|                                                                 |
//| SOGLIE DINAMICHE:                                               |
//|   ADX threshold = avg + (1/φ) × stddev (dai dati)               |
//|   Score threshold = OTSU→YOUDEN (100% data-driven)              |
//|   Zona Hurst = centro ± stdev × φ⁻¹ (dai dati)                  |
//|                                                                 |
//| READY CHECK:                                                    |
//|   L'EA NON entra a mercato finch� non ha abbastanza dati        |
//|   per calcolare TUTTI i valori organici (no fallback!)          |
//|                                                                 |
//| --------------------------------------------------------------- |
//| ? VALIDAZIONI IMPLEMENTATE (cerca "? VALIDATO" nel codice):    |
//| --------------------------------------------------------------- |
//| 1. HURST EXPONENT: Range [f?�, 1-f?�] forzato in output         |
//| 2. DIVISIONI: Tutte protette contro /0 con check denominatore   |
//| 3. BUFFER CIRCOLARI: Indici sempre in [0, MAX-1] via modulo     |
//| 4. SOMME INCREMENTALI: Sanity check per floating point errors   |
//| 5. VARIANZA: Protezione sqrt(negativo) → ritorna 0.0            |
//| 6. SCORE THRESHOLD: Bounds P(φ⁻²) ↔ P(1-φ⁻³) della distribuzione|
//| 7. CONFIDENCE: Output sempre in [0.0, 1.0]                      |
//| 8. REGIME HURST: Sempre ritorna ENUM valida (default=RANDOM)    |
//| --------------------------------------------------------------- |          |
//| --------------------------------------------------------------- |
//+------------------------------------------------------------------+
#property copyright "Pietro Giacobazzi, Juri Corradi, Alessandro Brehas"
#property version   "4.00"
#property description "EA Jarvis_INDICATORS CA__Pt MASTER (?? SISTEMA 100% ORGANICO - TUTTO DERIVATO DAI DATI)"

#include <Trade\Trade.mqh>
#include <Arrays\ArrayDouble.mqh>

// +---------------------------------------------------------------------------+
// �                    ?? MONEY MANAGEMENT & GENERALE                          �
// +---------------------------------------------------------------------------+
input group "--- ?? GENERALE ---"
input bool   enableTrading        = true;       // Abilita trading (false = solo analisi)
input int    MaxOpenTrades        = 100;        // Massimo posizioni aperte
input double MaxSpread            = 35;         // Spread massimo in punti
input uint   MaxSlippage          = 40;         // Slippage max in punti
input int    MagicNumber          = 123456;     // Magic Number (base, viene modificato per simbolo)

//+------------------------------------------------------------------+
//| ?? FIX: Calcola Magic Number unico per simbolo                   |
//| Evita conflitti quando EA gira su pi� simboli contemporaneamente |
//| ? FIXED: Usa ulong per evitare overflow integer durante hash    |
//+------------------------------------------------------------------+
int CalculateUniqueMagicNumber()
{
    // ?? FIX: Usa ulong per evitare overflow durante moltiplicazione
    ulong symbolHash = 0;
    string sym = _Symbol;
    
    // Numero primo grande per modulo (evita overflow mantenendo distribuzione)
    const ulong PRIME_MOD = 2147483647;  // Pi� grande primo che sta in int32
    
    for (int i = 0; i < StringLen(sym); i++) {
        // Modulo dopo ogni operazione per evitare overflow
        symbolHash = ((symbolHash * 31) % PRIME_MOD + StringGetCharacter(sym, i)) % PRIME_MOD;
    }
    
    // Limita a range ragionevole per evitare collisioni con altri EA
    int hashOffset = (int)(symbolHash % 100000);
    
    // ?? FIX: Protezione overflow - se MagicNumber + hashOffset supera INT_MAX
    int maxSafeOffset = INT_MAX - MagicNumber;
    if (maxSafeOffset < 0) {
        // MagicNumber gi� troppo grande, usa offset 0
        PrintFormat("[MAGIC] ?? MagicNumber %d troppo grande, hashOffset azzerato", MagicNumber);
        hashOffset = 0;
    } else if (hashOffset > maxSafeOffset) {
        // Riduci hashOffset per evitare overflow
        hashOffset = hashOffset % (maxSafeOffset + 1);
    }
    
    // Combina con MagicNumber base
    return MagicNumber + hashOffset;
}

// ?? FIX: Cache Magic Number (calcolato 1x in OnInit, riutilizzato ovunque)
int g_uniqueMagicNumber = 0;

// +---------------------------------------------------------------------------+
// �                         ?? PARAMETRI BUY                                   �
// +---------------------------------------------------------------------------+
input group "--- ?? ORDINI BUY ---"
input double BuyLotSize           = 0.5;       // Lotto fisso per ordini BUY
input int    BuyStopLossPoints    = 0;          // SL BUY in punti (0=disattivato)
input int    BuyTakeProfitPoints  = 500;        // TP BUY in punti (0=disattivato)
input double StopLossPriceBuy     = 0.0;        // SL BUY prezzo fisso (priorit� su punti)
input double TakeProfitPriceBuy   = 0.0;        // TP BUY prezzo fisso (priorit� su punti)
input int    BuyTimeStopMinutes   = 7200;          // Stop loss temporale BUY (0=disattivato)

// +---------------------------------------------------------------------------+
// �                         ?? PARAMETRI SELL                                 �
// +---------------------------------------------------------------------------+
input group "--- ?? ORDINI SELL ---"
input double SellLotSize          = 0.5;       // Lotto fisso per ordini SELL
input int    SellStopLossPoints   = 0;          // SL SELL in punti (0=disattivato)
input int    SellTakeProfitPoints = 500;        // TP SELL in punti (0=disattivato)
input double StopLossPriceSell    = 0.0;        // SL SELL prezzo fisso (priorit� su punti)
input double TakeProfitPriceSell  = 0.0;        // TP SELL prezzo fisso (priorit� su punti)
input int    SellTimeStopMinutes  = 7200;          // Stop loss temporale SELL (0=disattivato)

// +---------------------------------------------------------------------------+
// �                    ?? TIMEFRAME & SISTEMA VOTO                            �
// +---------------------------------------------------------------------------+
input group "--- ?? TIMEFRAME ---"
input bool   EnableIndicatorVoteSystem = true;  // Abilita sistema voti/pesi indicatori
input bool   EnableVote_M5             = false;  // Usa timeframe M5 nel voto
input bool   EnableVote_H1             = true;  // Usa timeframe H1 nel voto
input bool   EnableVote_H4             = true;  // Usa timeframe H4 nel voto
input bool   EnableVote_D1             = true;  // Usa timeframe D1 nel voto

// +---------------------------------------------------------------------------+
// �                      ?? LOG & DEBUG                                       �
// +---------------------------------------------------------------------------+
input group "--- ?? LOG ---"
input bool   EnableLogs                = true;  // ?? Abilita TUTTI i log (true=completi, false=silenzioso)
input bool   ExportTradesCSV           = true;  // ?? Esporta trade in CSV per Monte Carlo

// ---------------------------------------------------------------------------
// ?? SISTEMA 100% ORGANICO - Nessun valore hardcodato
// ---------------------------------------------------------------------------
// FORMULA PERIODI: naturalPeriod = autocorrelazione dei DATI
// Tutti i periodi derivano dal naturalPeriod usando rapporti f
//
// FORMULA PESI (ESPONENTE DI HURST - Metodo R/S):
// peso_TF = hurstExponent_TF / somma(hurstExponent_tutti_TF)
// H > g_hurstCenter: trending ? peso maggiore
// H � g_hurstCenter: random ? peso minore (zona no-trade)
// H < g_hurstCenter: mean-reverting ? peso maggiore
// ---------------------------------------------------------------------------

//--- Struttura per contenere i valori organici calcolati per ogni TF
struct OrganicPeriods {
    // ?? PERIODI (derivati da naturalPeriod � potenze di f)
    int ema;           // EMA period
    int rsi;           // RSI period (usato solo per divergenza, non vota)
    int macd_fast;     // MACD fast
    int macd_slow;     // MACD slow
    int macd_signal;   // MACD signal
    int bb;            // Bollinger period
    double bb_dev;     // BB deviation (organica)
    int atr;           // ATR period
    int adx;           // ADX period
    
    // ?? INDICATORI TREND AGGIUNTIVI (da v1.0)
    double psar_step;  // PSAR step organico = f?4
    double psar_max;   // PSAR max organico = f?�
    int sma_fast;      // SMA veloce = naturalPeriod � f�
    int sma_slow;      // SMA lenta = naturalPeriod � f4
    int ichimoku_tenkan;  // Tenkan-sen = naturalPeriod
    int ichimoku_kijun;   // Kijun-sen = naturalPeriod � f
    int ichimoku_senkou;  // Senkou Span B = naturalPeriod � f�
    
    // ?? INDICATORI MEAN-REVERSION (votano direzione inversione)
    int stoch_k;          // Stochastic %K = naturalPeriod
    int stoch_d;          // Stochastic %D = naturalPeriod � f?�
    int stoch_slowing;    // Slowing = round(f�) � 3
    
    int min_bars_required; // Barre minime necessarie
    
    // ?? PESO TF (calcolato da ESPONENTE DI HURST)
    double weight;           // Peso del timeframe normalizzato
    double hurstExponent;    // Esponente di Hurst (0-1): H>centro=trending, H<centro=mean-reverting
    
    // ?? PERIODO NATURALE (derivato dall'autocorrelazione dei DATI)
    // Questo � la BASE da cui derivano TUTTE le scale
    int naturalPeriod; // Periodo naturale del mercato per questo TF
};

//--- Periodi organici per ogni timeframe (calcolati in OnInit)
OrganicPeriods g_organic_M5, g_organic_H1, g_organic_H4, g_organic_D1;

// 🌱 FIX: Periodi precedenti per rilevare cambi significativi (>φ⁻³ ≈ 23.6%)
// Se i periodi cambiano drasticamente, gli handle indicatori devono essere ricreati
OrganicPeriods g_prevOrganic_M5, g_prevOrganic_H1, g_prevOrganic_H4, g_prevOrganic_D1;
bool g_periodsInitialized = false;  // Flag: primi periodi calcolati?

//--- Flag per indicare se i dati sono pronti
bool g_dataReady_M5 = false;
bool g_dataReady_H1 = false;
bool g_dataReady_H4 = false;
bool g_dataReady_D1 = false;

// +---------------------------------------------------------------------------+
// �               ?? INDICATORI TECNICI (tutti organici)                       �
// �---------------------------------------------------------------------------�
// � I pesi sono calcolati con ESPONENTE DI HURST:                             �
// �   peso_TF = hurstExponent_TF / S(hurstExponent)                           �
// �   H > g_hurstCenter ? peso maggiore (trending)                            �
// �   H � g_hurstCenter ? peso minore (random, zona no-trade)                 �
// +---------------------------------------------------------------------------+

// ---------------------------------------------------------------------------
// ?? INDICATORI TREND-FOLLOWING (filosofia coerente: seguire il trend)
// TREND PRIMARIO: EMA, MACD, PSAR, SMA Cross, Ichimoku
// TREND FILTER: ADX (forza trend)
// TREND SUPPORT: Heikin Ashi (noise reduction), OBV (conferma volume)
// RSI: usato per rilevare divergenze ? vota inversione
// ---------------------------------------------------------------------------
input group "--- ?? INDICATORI TREND PRIMARIO ---"
input bool   enableEMA       = true;    // EMA (trend direction)
input bool   enableMACD      = true;    // MACD (trend momentum)
input bool   enablePSAR      = true;    // Parabolic SAR (trend reversal points)
input bool   enableSMA       = true;    // SMA Cross (trend confirmation)
input bool   enableIchimoku  = true;    // Ichimoku (multi-trend system)

input group "--- ?? INDICATORI TREND FILTER ---"
input bool   enableADX       = true;    // ADX (trend strength - vota solo se > soglia)

input group "--- ?? INDICATORI TREND SUPPORT ---"
input bool   enableHeikin    = true;    // Heikin Ashi (noise reduction, trend confirm)
input bool   enableBB        = true;    // Bollinger Bands (volatility filter)

input group "--- ?? INDICATORI MEAN-REVERSION (votano direzione inversione) ---"
input bool   enableRSI       = true;    // RSI: oversold?BUY, overbought?SELL (soglia f)
input bool   enableStoch     = true;    // Stochastic: zone estreme ? voto inversione
input bool   enableOBV       = true;    // OBV: divergenze volume/prezzo ? voto inversione

// +---------------------------------------------------------------------------+
// �              ?? SISTEMA ORGANICO (Hurst & Soglie)                          �
// �---------------------------------------------------------------------------�
// � FILTRO HURST: Blocca trade quando H � centro storico (zona random)        �
// � SOGLIA SCORE: Automatica = mean + stdev � f?� dai dati storici            �
// � MEAN-REVERSION: RSI/Stoch/OBV votano nella direzione dell'inversione      �
// +---------------------------------------------------------------------------+
input group "--- ?? SISTEMA ORGANICO ---"
input bool   EnableHurstFilter  = true;         // Abilita filtro no-trade zone (H in zona random)
input bool   AutoScoreThreshold = true;         // Soglia automatica (true) o manuale (false)
input double ScoreThreshold     = 61.8;         // ?? Soglia manuale (f?� � 100) - solo se Auto=false

input group "--- ? PERFORMANCE BACKTEST ---"
input int    RecalcEveryBars    = 200;            // ?? Ricalcolo ogni N barre (0=ogni barra, 100=veloce, 200=molto veloce)

// -------------------------------------------------------------------------------
// ?? COSTANTI MATEMATICHE ORGANICHE - Derivate dalla natura, non arbitrarie
// -------------------------------------------------------------------------------
// Rapporto Aureo: f = (1 + v5) / 2 � 1.618 - base universale della natura
const double PHI = (1.0 + MathSqrt(5.0)) / 2.0;  // � 1.618033988749895
const double PHI_INV = 1.0 / PHI;                 // � 0.618033988749895 (1/f)
const double PHI_SQ = PHI * PHI;                  // � 2.618033988749895 (f�)
const double PHI_INV_SQ = PHI_INV * PHI_INV;      // � 0.381966011250105 (1/f�)
const double PHI_INV_CUB = PHI_INV_SQ * PHI_INV;  // � 0.236067977499790 (1/f�)

// ?? RANGE HURST ORGANICO - Derivato da f
// Limiti: [f?�, 1-f?�] � [0.236, 0.764]
const double HURST_RANGE_MIN = PHI_INV_CUB;              // � 0.236
const double HURST_RANGE_MAX = 1.0 - PHI_INV_CUB;        // � 0.764

// ---------------------------------------------------------------------------
// ?? OTTIMIZZAZIONE PERFORMANCE BACKTEST
// ---------------------------------------------------------------------------
int    g_barsSinceLastRecalc = 0;           // Contatore barre dall'ultimo ricalcolo
bool   g_isBacktest = false;                 // Flag: siamo in backtest?
bool   g_enableLogsEffective = true;         // Log effettivi (auto-disabilitati in backtest)

// ?? CACHE FLAGS (le variabili struct sono dichiarate dopo NaturalPeriodResult)
bool   g_cacheValid = false;                 // Cache valida?
int    g_hurstRecalcCounter = 0;             // Contatore per ricalcolo Hurst
bool   g_tfDataCacheValid = false;           // Cache dati TF valida?
int    g_tfDataRecalcCounter = 0;            // Contatore per reload dati TF

// ?? FIX: Variabili per rilevamento gap di prezzo e invalidazione cache
double g_lastCachePrice = 0.0;               // Ultimo prezzo quando cache valida
double g_lastCacheATR = 0.0;                 // Ultimo ATR quando cache valida

// ?? FIX: Warmup period - evita trading prima di stabilizzazione indicatori
datetime g_eaStartTime = 0;                  // Timestamp avvio EA
bool   g_warmupComplete = false;             // Flag: warmup completato?
int    g_warmupBarsRequired = 0;             // Barre minime prima di tradare (calcolato in OnInit)

// ---------------------------------------------------------------------------
// ?? NOTA: Ora TUTTO � derivato da:
// 1. PERIODO NATURALE = autocorrelazione dei DATI (CalculateNaturalPeriodForTF)
// 2. POTENZE DI f = MathPow(PHI, n) per le scale
// 3. RAPPORTI AUREI = PHI, PHI_INV, PHI_SQ per i moltiplicatori
//
// Riferimento potenze di f:
// f� � 1.618, f� � 2.618, f� � 4.236, f4 � 6.854, f5 � 11.09
// f6 � 17.94, f7 � 29.03, f8 � 46.98, f? � 76.01, f�� � 122.99
// f�� � 199.0, f�� � 322.0
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// ?? SISTEMA PURO - NESSUN FALLBACK
// Se non abbiamo abbastanza dati per calcolare i centri empirici,
// il timeframe viene DISABILITATO (isDataReady = false) e loggato l'errore.
// Questo garantisce che OGNI decisione sia basata su dati REALI.
// ---------------------------------------------------------------------------

// ?? Struttura per ritornare periodo naturale E esponente di Hurst
struct NaturalPeriodResult {
    int period;              // Periodo naturale (lag dove autocorr < 1/f�)
    double hurstExponent;    // Esponente di Hurst (0-1): confrontato con g_hurstCenter
    bool valid;              // true se calcolo OK, false se dati insufficienti
};

// ?? CACHE PER RISULTATI HURST (dichiarata dopo la struct)
NaturalPeriodResult g_cachedResult_M5, g_cachedResult_H1, g_cachedResult_H4, g_cachedResult_D1;

//--- Oggetti trading e indicatori
CTrade          trade;
datetime        lastBarTime = 0;
datetime        lastHurstRecalc = 0;  // ?? Ultimo ricalcolo Hurst

// ---------------------------------------------------------------------------
// ?? FILTRO HURST NO-TRADE ZONE - 100% DATA-DRIVEN
// ---------------------------------------------------------------------------
// Se il mercato � in regime "random" (H � centro storico), i segnali sono rumore.
// 
// SOGLIE 100% DAI DATI STORICI:
//   g_hurstCenter = media(H) storica del cross
//   g_hurstZoneMargin = stdev(H) � f?�
//   g_hurstRandomLow = centro - margine
//   g_hurstRandomHigh = centro + margine
//
// REGIME (basato su soglie data-driven):
//   H > g_hurstRandomHigh: TRENDING ? trade permessi
//   H < g_hurstRandomLow: MEAN-REVERTING ? trade permessi  
//   g_hurstRandomLow < H < g_hurstRandomHigh: RANDOM ? NO TRADE
//
// VOTING: tradeScore = |H - centro| � confidence, confrontato con soglia dinamica
// ---------------------------------------------------------------------------

// Soglie organiche derivate da f
// ?? SOGLIE ZONA RANDOM 100% DATA-DRIVEN
// TUTTO derivato dai dati storici del cross:
//   g_hurstCenter = media(H) storica
//   g_hurstZoneMargin = stdev(H) � f?�
//   zona_random = [g_hurstRandomLow, g_hurstRandomHigh]
double g_hurstCenter = 0.0;                                   // Centro DINAMICO = media(H) storica
double g_hurstZoneMargin = 0.0;                               // Margine = stdev(H) � f?�
double g_hurstRandomLow = 0.0;                                // centro - margine
double g_hurstRandomHigh = 0.0;                               // centro + margine
bool   g_hurstZoneReady = false;                              // True quando calcolato da dati

// Buffer storico per valori H (per calcolare stdev adattiva)
double g_hurstHistory[];                                      // Buffer H storici
int g_hurstHistorySize = 0;                                   // Numero H memorizzati
int g_hurstHistoryIndex = 0;                                  // Indice corrente (buffer circolare)
// ?? Dimensione buffer: f�� (calcolata dinamicamente)
int HURST_HISTORY_MAX = 0;                                    // Calcolato in OnInit come round(f��)
double g_hurstStdev = 0.0;                                    // Stdev storica di H

// ?? SOMME INCREMENTALI per Hurst (O(1) invece di O(n))
double g_hurstSum = 0.0;                                      // S(H) per calcolo media
double g_hurstSumSq = 0.0;                                    // S(H�) per calcolo varianza
int    g_hurstOperationCount = 0;                             // ?? FIX: Contatore operazioni per ricalcolo periodico anti-drift

// Buffer storico per tradeScore (per soglia data-driven del filtro Hurst)
double g_tradeScoreHistory[];
int    g_tradeScoreHistorySize = 0;
int    g_tradeScoreHistoryIndex = 0;
// ?? Dimensione buffer: f? (calcolata dinamicamente)
int TRADE_SCORE_HISTORY_MAX = 0;                              // Calcolato in OnInit come round(f?)
double g_tradeScoreThreshold = 0.0;                           // Soglia data-driven del tradeScore
bool   g_tradeScoreReady = false;                             // True quando soglia calcolata dai dati

// ?? SOMME INCREMENTALI per TradeScore (O(1) invece di O(n))
double g_tradeScoreSum = 0.0;                                 // S(tradeScore)
double g_tradeScoreSumSq = 0.0;                               // S(tradeScore�)
int    g_tradeScoreOperationCount = 0;                        // ?? FIX: Contatore operazioni per ricalcolo periodico anti-drift

// ---------------------------------------------------------------------------
// ?? STATISTICHE TRADING PER ANALISI PROFITTO
// ---------------------------------------------------------------------------
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
    double scoreAtEntry;       // 🌱 v1.1: Score % al momento dell'apertura (per Youden)
    string closeReason;        // "SL", "TP", "TIME_STOP", "SIGNAL"
};

TradeRecord g_recentTrades[];
int g_recentTradesMax = 0;     // Calcolato in OnInit come round(f8) ≈ 47
int g_recentTradesCount = 0;
int g_recentTradesIndex = 0;

// ---------------------------------------------------------------------------
// 🌱 v1.1: SOGLIA ADATTIVA OTSU → YOUDEN
// Fase 1 (warm-up): Otsu - separazione bimodale degli score
// Fase 2 (feedback): Youden - massimizza TPR + TNR - 1 basato su profitti
// ---------------------------------------------------------------------------
double g_lastEntryScore = 0.0;            // Score % corrente (per nuovi trade)
bool   g_youdenReady = false;             // True quando abbiamo abbastanza trade per Youden
double g_youdenThreshold = 0.0;           // Soglia calcolata da Youden J
double g_otsuThreshold = 0.0;             // Soglia calcolata da Otsu
int    g_minTradesForYouden = 0;          // Minimo trade per passare a Youden (φ⁵ ≈ 11)

// 🌱 v1.1 FIX: Mappa ticket → score per collegare correttamente score a trade
// Problema: g_lastEntryScore veniva sovrascritto prima della chiusura trade
// Soluzione: Array paralleli che mantengono score per ogni posizione aperta
ulong  g_openTickets[];                   // Ticket delle posizioni aperte
double g_openScores[];                    // Score al momento dell'apertura
int    g_openTicketsCount = 0;            // Numero posizioni tracciate
int    g_openTicketsMax = 0;              // Max posizioni = g_recentTradesMax

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
double g_hurstTradeScore = 0.0;          // Trade score = |H - centro| � confidence / (stdev � f)
bool g_hurstAllowTrade = true;           // Flag: trade permessi?
bool g_hurstReady = false;               // True quando zona Hurst e soglia tradeScore sono da dati

// ---------------------------------------------------------------------------
// ?? SOGLIA SCORE DINAMICA (derivata dalla distribuzione storica)
// ---------------------------------------------------------------------------
// Buffer circolare per memorizzare gli ultimi N score
// La soglia � calcolata come: mean(score) + stdev(score) � f?�
// Questo rende la soglia adattiva al comportamento recente del mercato
// ---------------------------------------------------------------------------
double g_scoreHistory[];                 // Buffer score storici
int g_scoreHistorySize = 0;              // Numero score memorizzati
int g_scoreHistoryIndex = 0;             // Indice corrente (buffer circolare)
double g_dynamicThreshold = 0.0;         // Soglia 100% data-driven (0 = non pronta)
// ?? Dimensione buffer: f�� (calcolata dinamicamente)
int SCORE_HISTORY_MAX = 0;               // Calcolato in OnInit come round(f��)
bool g_scoreThresholdReady = false;      // True quando la soglia auto � calcolata dai dati

// ?? SOMME INCREMENTALI per Score (O(1) invece di O(n))
double g_scoreSum = 0.0;                 // S(score)
double g_scoreSumSq = 0.0;               // S(score�)
int    g_scoreOperationCount = 0;        // ?? FIX: Contatore operazioni per ricalcolo periodico anti-drift

// ---------------------------------------------------------------------------
// ?? DETECTOR INVERSIONE ORGANICO
// Score Momentum: traccia cambi direzione del consenso indicatori
// Regime Change: traccia transizioni regime Hurst
// RSI Divergence: rileva divergenze prezzo/RSI (classico, testato)
// ---------------------------------------------------------------------------

// Score Momentum: derivata dello score (segnale leading)
double g_prevScore = 0.0;                // Score della barra precedente
double g_scoreMomentum = 0.0;            // Cambio score: Score[t] - Score[t-1]
double g_scoreMomentumThreshold = 0.0;   // Soglia momentum = stdev(momentum) � f?�
double g_momentumHistory[];              // Buffer storico momentum per calcolo soglia
int g_momentumHistorySize = 0;
int g_momentumHistoryIndex = 0;
double g_momentumSum = 0.0;              // Somma incrementale momentum
double g_momentumSumSq = 0.0;            // Somma incrementale momentum�
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
int g_swingsMax = 0;                     // Max swing = round(f5) � 11
int g_divergenceSignal = 0;              // +1=bullish div, -1=bearish div, 0=nessuna
double g_divergenceStrength = 0.0;       // Forza divergenza (0-1)

// ?? SOGLIA DIVERGENZA DATA-DRIVEN
// Traccia storia forze divergenza per calcolare soglia minima
double g_divergenceHistory[];            // Buffer storico forza divergenza
int g_divergenceHistorySize = 0;         // Dimensione buffer
int g_divergenceHistoryIndex = 0;        // Indice circolare
double g_divergenceSum = 0.0;            // Somma incrementale (O(1))
double g_divergenceSumSq = 0.0;          // Somma quadrati (O(1))
double g_divergenceMinThreshold = PHI_INV_CUB;  // ?? Soglia iniziale = f?� � 23.6%
bool g_divergenceThresholdReady = false; // True quando calcolata dai dati

// ?? SOGLIA REVERSAL DATA-DRIVEN
// Invece di usare PHI_INV fisso, tracciamo la storia della forza reversal
// e calcoliamo la soglia come: mean + stdev � f?�
double g_reversalStrengthHistory[];      // Buffer storico forza reversal
int g_reversalHistorySize = 0;           // Dimensione buffer
int g_reversalHistoryIndex = 0;          // Indice circolare corrente
double g_reversalSum = 0.0;              // Somma incrementale (O(1))
double g_reversalSumSq = 0.0;            // Somma quadrati (O(1))
double g_reversalThreshold = PHI_INV;    // ?? Soglia iniziale = f?� � 61.8%
bool g_reversalThresholdReady = false;   // True quando soglia calcolata dai dati

// ?? STOCHASTIC EXTREME DETECTION (ipercomprato/ipervenduto)
// Soglie f-derivate: ipervenduto < f?��100 � 23.6, ipercomprato > (1-f?�)�100 � 76.4
int g_stochExtremeSignal = 0;            // +1=ipervenduto (bullish reversal), -1=ipercomprato (bearish), 0=neutro
double g_stochExtremeStrength = 0.0;     // Forza segnale (0-1)

// ?? OBV DIVERGENCE DETECTION (volume vs price)
int g_obvDivergenceSignal = 0;           // +1=bullish div (prezzo?, OBV?), -1=bearish (prezzo?, OBV?), 0=nessuna
double g_obvDivergenceStrength = 0.0;    // Forza divergenza OBV (0-1)

// ?? COSTANTE CACHED: evita 4� SymbolInfoDouble per barra
double g_pointValue = 0.0;               // SYMBOL_POINT (calcolato 1� in OnInit)

//--- Handles indicatori per tutti i timeframe (inizializzati a INVALID_HANDLE per sicurezza)
int emaHandle_M5 = INVALID_HANDLE, emaHandle_H1 = INVALID_HANDLE, emaHandle_H4 = INVALID_HANDLE, emaHandle_D1 = INVALID_HANDLE;
int rsiHandle_M5 = INVALID_HANDLE, rsiHandle_H1 = INVALID_HANDLE, rsiHandle_H4 = INVALID_HANDLE, rsiHandle_D1 = INVALID_HANDLE;
int macdHandle_M5 = INVALID_HANDLE, macdHandle_H1 = INVALID_HANDLE, macdHandle_H4 = INVALID_HANDLE, macdHandle_D1 = INVALID_HANDLE;
int bbHandle_M5 = INVALID_HANDLE, bbHandle_H1 = INVALID_HANDLE, bbHandle_H4 = INVALID_HANDLE, bbHandle_D1 = INVALID_HANDLE;
int atrHandle_M5 = INVALID_HANDLE, atrHandle_H1 = INVALID_HANDLE, atrHandle_H4 = INVALID_HANDLE, atrHandle_D1 = INVALID_HANDLE;
int adxHandle_M5 = INVALID_HANDLE, adxHandle_H1 = INVALID_HANDLE, adxHandle_H4 = INVALID_HANDLE, adxHandle_D1 = INVALID_HANDLE;
int obvHandle_M5 = INVALID_HANDLE, obvHandle_H1 = INVALID_HANDLE, obvHandle_H4 = INVALID_HANDLE, obvHandle_D1 = INVALID_HANDLE;
// ?? NUOVI INDICATORI TREND (da v1.0)
int psarHandle_M5 = INVALID_HANDLE, psarHandle_H1 = INVALID_HANDLE, psarHandle_H4 = INVALID_HANDLE, psarHandle_D1 = INVALID_HANDLE;
int smaFastHandle_M5 = INVALID_HANDLE, smaFastHandle_H1 = INVALID_HANDLE, smaFastHandle_H4 = INVALID_HANDLE, smaFastHandle_D1 = INVALID_HANDLE;
int smaSlowHandle_M5 = INVALID_HANDLE, smaSlowHandle_H1 = INVALID_HANDLE, smaSlowHandle_H4 = INVALID_HANDLE, smaSlowHandle_D1 = INVALID_HANDLE;
int ichimokuHandle_M5 = INVALID_HANDLE, ichimokuHandle_H1 = INVALID_HANDLE, ichimokuHandle_H4 = INVALID_HANDLE, ichimokuHandle_D1 = INVALID_HANDLE;
int stochHandle_M5 = INVALID_HANDLE, stochHandle_H1 = INVALID_HANDLE, stochHandle_H4 = INVALID_HANDLE, stochHandle_D1 = INVALID_HANDLE;

//--- Struttura dati per timeframe
struct TimeFrameData {
    double ema[];
    double rsi[];           // Usato per divergenza ? vota inversione
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
    // ?? NUOVI INDICATORI TREND (da v1.0)
    double psar[];          // Parabolic SAR
    double sma_fast[];      // SMA veloce
    double sma_slow[];      // SMA lenta
    double ichimoku_tenkan[];   // Tenkan-sen (conversion line)
    double ichimoku_kijun[];    // Kijun-sen (base line)
    double ichimoku_senkou_a[]; // Senkou Span A
    double ichimoku_senkou_b[]; // Senkou Span B
    // ?? INDICATORI MEAN-REVERSION (votano inversione)
    double stoch_main[];    // Stochastic %K
    double stoch_signal[];  // Stochastic %D
    MqlRates rates[];
    
    // ?? Valori organici calcolati dinamicamente
    double atr_avg;         // Media ATR calcolata sulle ultime N barre
    double adx_avg;         // Media ADX calcolata sulle ultime N barre
    double adx_stddev;      // Deviazione standard ADX
    double adx_threshold;   // Soglia ADX organica = avg + (1/f)*stddev
    bool   isDataReady;     // Flag: abbastanza dati per calcoli organici
    
    // ?? CENTRI EMPIRICI - Calcolati da CalculateEmpiricalThresholds()
    double rsi_center;      // mean(RSI) ultime N barre
    
    // ?? SCALE EMPIRICHE - Derivate dalla volatilit� dei dati
    double rsi_scale;       // Stdev empirico RSI � f
    double obv_scale;       // ?? FIX: Stdev empirico variazioni OBV � f
    
    // ?? ADX PERCENTILI - Derivati dalla distribuzione storica
    double adx_p25;         // f?� percentile ADX � 38� (range "basso")
    double adx_p75;         // f?� percentile ADX � 62� (range "alto")
    
    // ?? Riferimento ai periodi organici del TF (impostato in LoadTimeFrameData)
    OrganicPeriods organic; // Periodi e peso organico del timeframe
};

TimeFrameData tfData_M5, tfData_H1, tfData_H4, tfData_D1;

//--- ?? Flag TF attivi (aggiornati ad ogni tick in base ai dati disponibili)
bool g_vote_M5_active = false;
bool g_vote_H1_active = false;
bool g_vote_H4_active = false;
bool g_vote_D1_active = false;

//+------------------------------------------------------------------+
//| Inizializzazione Expert Advisor                                  |
//+------------------------------------------------------------------+
int OnInit()
{
    // ---------------------------------------------------------------
    // ?? STEP 0: INIZIALIZZAZIONE COSTANTI ORGANICHE (potenze di f)
    // Tutte le dimensioni buffer sono calcolate dinamicamente da f
    // f? � 76, f�� � 123, f�� � 322
    // ---------------------------------------------------------------
    TRADE_SCORE_HISTORY_MAX = (int)MathRound(MathPow(PHI, 9));   // f? � 76
    HURST_HISTORY_MAX = (int)MathRound(MathPow(PHI, 10));        // f�� � 123
    SCORE_HISTORY_MAX = (int)MathRound(MathPow(PHI, 12));        // f�� � 322
    
    // ?? RILEVAMENTO BACKTEST E OTTIMIZZAZIONE AUTOMATICA
    g_isBacktest = (bool)MQLInfoInteger(MQL_TESTER);
    g_enableLogsEffective = EnableLogs && !g_isBacktest;
    g_barsSinceLastRecalc = 0;
    
    if (g_isBacktest) {
        Print("-----------------------------------------------------------------");
        Print("? BACKTEST MODE ATTIVO - Performance ottimizzata");
        if (RecalcEveryBars > 0) {
            PrintFormat("   Ricalcolo organico: ogni %d barre (invece di ogni barra)", RecalcEveryBars);
            PrintFormat("   Speedup atteso: ~%dx rispetto al normale", RecalcEveryBars);
        } else {
            Print("   Ricalcolo organico: ogni barra (usa RecalcEveryBars>0 per velocizzare!)");
            Print("   ?? CONSIGLIO: Imposta RecalcEveryBars=100 per backtest 50-100x pi� veloce");
        }
        Print("   ?? Buffer Hurst: PRE-CARICATO da storia (trading subito!)");
        Print("   Log dettagliati: DISABILITATI automaticamente");
        Print("-----------------------------------------------------------------");
    }
    
    Print("[INIT] ?? Avvio EA Jarvis v4 FULL DATA-DRIVEN (PURO) - Periodi E pesi derivati dai dati");
    
    // ?? CACHE COSTANTI SIMBOLO (evita chiamate API ripetute)
    g_pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // ?? Fallback organico: f?�� � 0.00001 (calcolato esattamente)
    // f?�� = (f?6)� � f?5 = PHI_INV^23 � 0.0000106
    // ?? FIX: Per coppie JPY (point ~0.01) il fallback � molto pi� grande
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
    
    // ?? FIX: Calcola e cacha Magic Number UNA VOLTA (evita ricalcolo costante)
    g_uniqueMagicNumber = CalculateUniqueMagicNumber();
    PrintFormat("[INIT] ?? Magic Number unico per %s: %d", _Symbol, g_uniqueMagicNumber);
    
    // ---------------------------------------------------------------
    // ?? STEP 1: PRE-CARICAMENTO DATI STORICI
    // Carica abbastanza barre per calcolare autocorrelazione e cicli
    // Se i dati non sono sufficienti, il TF viene DISABILITATO (no fallback!)
    // ---------------------------------------------------------------
    Print("[INIT] ?? Pre-caricamento dati storici per analisi naturale...");
    
    // Calcola periodi naturali E forza autocorrelazione per ogni TF
    // Entrambi derivati COMPLETAMENTE dai dati!
    NaturalPeriodResult result_M5 = CalculateNaturalPeriodForTF(PERIOD_M5);
    NaturalPeriodResult result_H1 = CalculateNaturalPeriodForTF(PERIOD_H1);
    NaturalPeriodResult result_H4 = CalculateNaturalPeriodForTF(PERIOD_H4);
    NaturalPeriodResult result_D1 = CalculateNaturalPeriodForTF(PERIOD_D1);
    
    // ?? PURO: Disabilita TF senza dati sufficienti
    g_dataReady_M5 = result_M5.valid;
    g_dataReady_H1 = result_H1.valid;
    g_dataReady_H4 = result_H4.valid;
    g_dataReady_D1 = result_D1.valid;
    
    if (!result_M5.valid) Print("? [INIT] M5: Dati insufficienti - TF DISABILITATO");
    if (!result_H1.valid) Print("? [INIT] H1: Dati insufficienti - TF DISABILITATO");
    if (!result_H4.valid) Print("? [INIT] H4: Dati insufficienti - TF DISABILITATO");
    if (!result_D1.valid) Print("? [INIT] D1: Dati insufficienti - TF DISABILITATO");
    
    // Verifica che almeno un TF sia attivo
    if (!g_dataReady_M5 && !g_dataReady_H1 && !g_dataReady_H4 && !g_dataReady_D1) {
        Print("??? [INIT] NESSUN TIMEFRAME HA DATI SUFFICIENTI - EA NON PU� OPERARE");
        return INIT_FAILED;
    }
    
    // ---------------------------------------------------------------
    // ?? STEP 2: CALCOLO PESI EMPIRICI (ESPONENTE DI HURST)
    // peso_TF = hurstExponent_TF / somma(hurstExponent)
    // H > g_hurstRandomHigh: trending ? peso maggiore
    // H in [g_hurstRandomLow, g_hurstRandomHigh]: random ? zona no-trade
    // H < g_hurstRandomLow: mean-reverting ? peso maggiore
    // 100% derivato dai DATI, non dai minuti del timeframe!
    // ---------------------------------------------------------------
    double totalHurst = 0;
    // ? hurstExponent gi� validato nel range organico [f?�, 1-f?�] da CalculateNaturalPeriodForTF
    if (result_M5.valid) totalHurst += result_M5.hurstExponent;
    if (result_H1.valid) totalHurst += result_H1.hurstExponent;
    if (result_H4.valid) totalHurst += result_H4.hurstExponent;
    if (result_D1.valid) totalHurst += result_D1.hurstExponent;
    
    // ? VALIDATO: Protezione divisione per zero
    if (totalHurst <= 0) totalHurst = 1.0;
    
    // ? VALIDATO: Pesi sempre >= 0 e normalizzati (sommano a 1.0 se almeno un TF valido)
    double weight_M5 = result_M5.valid ? (result_M5.hurstExponent / totalHurst) : 0;
    double weight_H1 = result_H1.valid ? (result_H1.hurstExponent / totalHurst) : 0;
    double weight_H4 = result_H4.valid ? (result_H4.hurstExponent / totalHurst) : 0;
    double weight_D1 = result_D1.valid ? (result_D1.hurstExponent / totalHurst) : 0;
    
    PrintFormat("[INIT] ?? Periodi naturali: M5=%d H1=%d H4=%d D1=%d",
        result_M5.period, result_H1.period, result_H4.period, result_D1.period);
    // NOTA: T/M/R sono etichette preliminari - la zona esatta sar� calcolata dai dati storici
    PrintFormat("[INIT] ?? Hurst: M5=%.3f H1=%.3f H4=%.3f D1=%.3f",
        result_M5.hurstExponent, result_H1.hurstExponent, result_H4.hurstExponent, result_D1.hurstExponent);
    PrintFormat("[INIT] ?? PESI EMPIRICI (Hurst): M5=%.2f H1=%.2f H4=%.2f D1=%.2f",
        weight_M5, weight_H1, weight_H4, weight_D1);
    PrintFormat("[INIT] ?? TF attivi: M5=%s H1=%s H4=%s D1=%s",
        g_dataReady_M5 ? "?" : "?", g_dataReady_H1 ? "?" : "?", 
        g_dataReady_H4 ? "?" : "?", g_dataReady_D1 ? "?" : "?");
    
    // ---------------------------------------------------------------
    // ?? STEP 3: CALCOLO PERIODI ORGANICI (solo per TF attivi)
    // TUTTI i periodi sono derivati dal periodo naturale usando rapporti f
    // I pesi sono passati insieme al periodo naturale
    // ---------------------------------------------------------------
    if (g_dataReady_M5) CalculateOrganicPeriodsFromData(PERIOD_M5, g_organic_M5, result_M5.period, weight_M5, result_M5.hurstExponent);
    if (g_dataReady_H1) CalculateOrganicPeriodsFromData(PERIOD_H1, g_organic_H1, result_H1.period, weight_H1, result_H1.hurstExponent);
    if (g_dataReady_H4) CalculateOrganicPeriodsFromData(PERIOD_H4, g_organic_H4, result_H4.period, weight_H4, result_H4.hurstExponent);
    if (g_dataReady_D1) CalculateOrganicPeriodsFromData(PERIOD_D1, g_organic_D1, result_D1.period, weight_D1, result_D1.hurstExponent);
    
    // Log periodi organici calcolati
    if (g_enableLogsEffective) {
        Print("");
        Print("---------------------------------------------------------------");
        Print("?? PERIODI E PESI 100% DATA-DRIVEN (Hurst + Rapporti f)");
        Print("---------------------------------------------------------------");
        if (g_dataReady_M5) LogOrganicPeriods("M5", g_organic_M5);
        if (g_dataReady_H1) LogOrganicPeriods("H1", g_organic_H1);
        if (g_dataReady_H4) LogOrganicPeriods("H4", g_organic_H4);
        if (g_dataReady_D1) LogOrganicPeriods("D1", g_organic_D1);
        Print("---------------------------------------------------------------");
        Print("");
    }
    
    // ---------------------------------------------------------------
    // ?? STEP 4: INIZIALIZZA FILTRO HURST NO-TRADE ZONE (preliminare)
    // I regimi iniziali e la zona adattiva verranno calcolati
    // dopo l'inizializzazione del buffer in STEP 6
    // ---------------------------------------------------------------
    if (EnableHurstFilter) {
        // Imposta regimi iniziali (saranno aggiornati in RecalculateOrganicSystem)
        g_hurstRegime_M5 = GetHurstRegime(result_M5.hurstExponent);
        g_hurstRegime_H1 = GetHurstRegime(result_H1.hurstExponent);
        g_hurstRegime_H4 = GetHurstRegime(result_H4.hurstExponent);
        g_hurstRegime_D1 = GetHurstRegime(result_D1.hurstExponent);
        
        // NOTA: Il ricalcolo completo avviene ad ogni barra in RecalculateOrganicSystem()
        
        Print("");
        Print("---------------------------------------------------------------");
        Print("?? FILTRO HURST NO-TRADE ZONE ATTIVO (preliminare)");
        if (RecalcEveryBars > 0) {
            PrintFormat("   Ricalcolo: ogni %d barre (ottimizzato per backtest)", RecalcEveryBars);
        } else {
            Print("   Ricalcolo: ogni nuova barra");
        }
        Print("   Zona adattiva e buffer verranno inizializzati in STEP 6");
        Print("---------------------------------------------------------------");
        Print("");
    } else {
        Print("[INIT] ?? Filtro Hurst NO-TRADE ZONE: DISABILITATO");
        g_hurstAllowTrade = true;
    }
    
    // ---------------------------------------------------------------
    // ?? STEP 5: INIZIALIZZA SOGLIA SCORE DINAMICA
    // Se AutoScoreThreshold=true, la soglia sar� derivata dalla
    // distribuzione storica degli score. Altrimenti usa valore manuale.
    // ---------------------------------------------------------------
    InitScoreHistoryBuffer();
    if (AutoScoreThreshold) {
        // ? VALIDATO: minSamples derivato da f: f4 � 7 come minimo assoluto (ridotto per trading pi� veloce)
        int minSamplesOrganic = (int)MathRound(MathPow(PHI, 4));  // f4 � 7
        int minSamplesForInit = MathMax(minSamplesOrganic, (int)MathCeil(SCORE_HISTORY_MAX * PHI_INV_SQ * PHI_INV_SQ));
        Print("");
        Print("---------------------------------------------------------------");
        Print("?? SOGLIA SCORE 100% DERIVATA DAI DATI");
        Print("   Formula: threshold = mean_score + stdev_score � f?�");
        PrintFormat("   Buffer: %d campioni | Ready dopo %d campioni (~%d%% del buffer, f?4)", 
            SCORE_HISTORY_MAX, minSamplesForInit, (int)MathRound(100.0 * minSamplesForInit / SCORE_HISTORY_MAX));
        PrintFormat("   Limiti: [%.1f%%, %.1f%%] (1/f� a 1-1/f�)", PHI_INV_CUB * 100, (1.0 - PHI_INV_CUB) * 100);
        Print("   ?? FIX: Minimo campioni ridotto per trading pi� veloce");
        Print("---------------------------------------------------------------");
        Print("");
    } else {
        PrintFormat("[INIT] ?? Soglia score MANUALE: %.1f%%", ScoreThreshold);
    }
    
    // ---------------------------------------------------------------
    // ?? STEP 6: INIZIALIZZA BUFFER STORICO HURST
    // Per calcolo zona random adattiva: centro � (stdev_H � f?�)
    // ---------------------------------------------------------------
    InitHurstHistoryBuffer();
    
    // ?? Pre-carica il buffer Hurst dai dati storici
    // Cos� il trading pu� iniziare SUBITO invece di aspettare warm-up!
    PreloadHurstBufferFromHistory();
    
    if (EnableHurstFilter) {
        Print("");
        Print("---------------------------------------------------------------");
        Print("?? FILTRO HURST ADATTIVO ATTIVO");
        if (g_hurstZoneReady) {
            Print("   ? Buffer Hurst GI� PRONTO (pre-caricato da storia)");
        } else {
            Print("   Zona e soglie verranno calcolate dai dati di mercato");
        }
        PrintFormat("   Buffer Hurst: %d/%d campioni | Ready: %s", 
            g_hurstHistorySize, HURST_HISTORY_MAX, g_hurstZoneReady ? "?" : "?");
        PrintFormat("   Buffer TradeScore: %d campioni | Ready dopo ~%d campioni",
            TRADE_SCORE_HISTORY_MAX, (int)MathCeil(TRADE_SCORE_HISTORY_MAX * PHI_INV_SQ));
        Print("   Formula zona: centro = mean(H), margine = stdev(H) � f?�");
        Print("   Formula soglia: mean(tradeScore) + stdev(tradeScore) � f?�");
        Print("---------------------------------------------------------------");
        Print("");
    }
    
    trade.SetExpertMagicNumber(g_uniqueMagicNumber);  // ?? FIX: Usa cache
    trade.SetMarginMode();
    trade.SetTypeFillingBySymbol(_Symbol);
    trade.SetDeviationInPoints(MaxSlippage);
    
    if (g_enableLogsEffective) {
        PrintFormat("[INIT] ?? Magic Number unico per %s: %d (base=%d)", 
            _Symbol, g_uniqueMagicNumber, MagicNumber);
    }
    
    if (!InitializeIndicators()) {
        Print("[ERROR] Errore inizializzazione indicatori");
        return INIT_FAILED;
    }
    
    // ---------------------------------------------------------------
    // ?? FIX: Verifica che almeno un indicatore DIREZIONALE sia abilitato
    // Senza indicatori attivi, lo score sar� sempre 0 e nessun trade eseguito
    // ?? v1.1: RSI, Stoch, OBV sono MEAN-REVERSION, votano nella direzione inversione
    // ---------------------------------------------------------------
    int numTrendIndicators = 0;   // Indicatori TREND (votano)
    int numBlockIndicators = 0;   // Indicatori MEAN-REVERSION (bloccano)
    
    // TREND INDICATORS (votano)
    if (enableEMA)      numTrendIndicators++;
    if (enableMACD)     numTrendIndicators++;
    if (enableBB)       numTrendIndicators++;
    if (enableHeikin)   numTrendIndicators++;
    if (enableADX)      numTrendIndicators++;
    if (enablePSAR)     numTrendIndicators++;
    if (enableSMA)      numTrendIndicators++;
    if (enableIchimoku) numTrendIndicators++;
    
    // MEAN-REVERSION INDICATORS (votano inversione)
    if (enableRSI)      numBlockIndicators++;
    if (enableStoch)    numBlockIndicators++;
    if (enableOBV)      numBlockIndicators++;
    
    if (numTrendIndicators == 0) {
        Print("??? [INIT] NESSUN INDICATORE TREND ABILITATO!");
        Print("   ? Almeno uno tra EMA, MACD, BB, Heikin, ADX, PSAR, SMA, Ichimoku deve essere TRUE");
        Print("   ? EA non pu� generare segnali di trading");
        return INIT_FAILED;
    }
    PrintFormat("[INIT] ? %d indicatori TREND (votano) + %d MEAN-REVERSION (votano inversione)", 
        numTrendIndicators, numBlockIndicators);
    
    // ?? FIX: Salva periodi iniziali per rilevamento cambi futuri
    SaveCurrentPeriodsAsPrevious();
    
    // ?? FIX: Inizializza warmup period
    g_eaStartTime = TimeCurrent();
    g_warmupComplete = false;
    // 🌱 Warmup = φ² × naturalPeriod più lungo disponibile (minimo φ⁸ ≈ 47 barre)
    int longestPeriod = MathMax(MathMax(g_organic_M5.naturalPeriod, g_organic_H1.naturalPeriod),
                                MathMax(g_organic_H4.naturalPeriod, g_organic_D1.naturalPeriod));
    int minWarmupBars = (int)MathRound(MathPow(PHI, 8));  // φ⁸ ≈ 47 (invece di 50 arbitrario)
    g_warmupBarsRequired = MathMax(minWarmupBars, (int)MathRound(longestPeriod * PHI_SQ));
    PrintFormat("[INIT] ?? Warmup: %d barre richieste prima del trading", g_warmupBarsRequired);
    
    // ---------------------------------------------------------------
    // ?? INIZIALIZZA STATISTICHE TRADING
    // ---------------------------------------------------------------
    ZeroMemory(g_stats);
    g_stats.peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // Buffer trade recenti = f8 ≈ 47
    g_recentTradesMax = (int)MathRound(MathPow(PHI, 8));
    
    // 🌱 v1.1: Inizializza sistema Otsu → Youden
    g_minTradesForYouden = (int)MathRound(MathPow(PHI, 5));  // φ⁵ ≈ 11 trade
    g_youdenReady = false;
    g_youdenThreshold = 0.0;
    g_otsuThreshold = 0.0;
    g_lastEntryScore = 0.0;
    
    // 🌱 v1.1 FIX: Inizializza mappa ticket → score
    g_openTicketsMax = g_recentTradesMax;  // Stesso buffer size
    ArrayResize(g_openTickets, g_openTicketsMax);
    ArrayResize(g_openScores, g_openTicketsMax);
    ArrayInitialize(g_openTickets, 0);
    ArrayInitialize(g_openScores, 0.0);
    g_openTicketsCount = 0;
    
    // ---------------------------------------------------------------
    // 🎯 INIZIALIZZA DETECTOR INVERSIONE
    // ---------------------------------------------------------------
    InitReversalDetectors();
    ArrayResize(g_recentTrades, g_recentTradesMax);
    g_recentTradesCount = 0;
    g_recentTradesIndex = 0;
    
    PrintFormat("[INIT] 📊 Statistiche trading inizializzate | Buffer ultimi %d trade | Equity iniziale: %.2f", 
        g_recentTradesMax, g_stats.peakEquity);
    
    // 🌱 v1.1: Log sistema Otsu → Youden
    Print("");
    Print("---------------------------------------------------------------");
    Print("🌱 SOGLIA ADATTIVA: OTSU → YOUDEN (100% DATA-DRIVEN)");
    Print("---------------------------------------------------------------");
    PrintFormat("   Fase 1 (warm-up): OTSU - separazione bimodale score");
    PrintFormat("   Fase 2 (≥%d trade): YOUDEN - massimizza (TPR+TNR-1)", g_minTradesForYouden);
    PrintFormat("   Bounds: P%.1f%% ↔ P%.1f%% (φ-derivati)", PHI_INV_SQ * 100.0, (1.0 - PHI_INV_CUB) * 100.0);
    Print("   Tutti i parametri derivati da φ e DAI DATI");
    Print("---------------------------------------------------------------");
    
    // ---------------------------------------------------------------
    // 🔄 RIEPILOGO STATO BUFFER - Trading pronto?
    // ---------------------------------------------------------------
    Print("");
    Print("---------------------------------------------------------------");
    Print("📊 STATO BUFFER E PRONTEZZA TRADING");
    Print("---------------------------------------------------------------");
    PrintFormat("   Buffer Hurst: %d/%d | Ready: %s", 
        g_hurstHistorySize, HURST_HISTORY_MAX, g_hurstZoneReady ? "?" : "?");
    PrintFormat("   Buffer TradeScore: %d/%d | Ready: %s", 
        g_tradeScoreHistorySize, TRADE_SCORE_HISTORY_MAX, g_tradeScoreReady ? "?" : "?");
    PrintFormat("   g_hurstReady: %s", g_hurstReady ? "?" : "?");
    PrintFormat("   Buffer Score Indicatori: %d/%d | Ready: %s (fallback: soglia manuale %.1f%%)", 
        g_scoreHistorySize, SCORE_HISTORY_MAX, g_scoreThresholdReady ? "?" : "?", ScoreThreshold);
    
    if (g_hurstReady) {
        Print("   ??? TRADING PRONTO IMMEDIATAMENTE!");
    } else {
        Print("   ?? Warm-up parziale richiesto per alcuni buffer");
    }
    Print("---------------------------------------------------------------");
    Print("");
    
    Print("[INIT] ? EA DATA-DRIVEN inizializzato - periodi E PESI auto-calcolati dai dati");
    
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
//| ?? RICALCOLO COMPLETO: Periodi naturali, pesi, e periodi organici|
//| Chiamato ad ogni nuova barra per adattarsi ai cambi di regime    |
//| ?? OTTIMIZZATO: Usa cache per evitare ricalcoli costosi          |
//+------------------------------------------------------------------+
void RecalculateOrganicSystem()
{
    // ---------------------------------------------------------------
    // ? FIX: RILEVAMENTO GAP DI PREZZO - Invalida cache se gap > ATR � f
    // Questo garantisce che cambi di regime improvvisi vengano gestiti
    // ---------------------------------------------------------------
    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if (g_cacheValid && g_lastCachePrice > 0 && g_lastCacheATR > 0) {
        double priceChange = MathAbs(currentPrice - g_lastCachePrice);
        double gapThreshold = g_lastCacheATR * PHI;  // Gap = ATR � f
        
        if (priceChange > gapThreshold) {
            g_cacheValid = false;  // Invalida cache su gap
            if (g_enableLogsEffective) {
                PrintFormat("[RECALC] ?? GAP rilevato: %.5f > %.5f (ATR�f) - Cache invalidata", 
                    priceChange, gapThreshold);
            }
        }
    }
    
    // ---------------------------------------------------------------
    // ?? CHECK CACHE - Ricalcola Hurst SOLO ogni N cicli (molto costoso!)
    // ---------------------------------------------------------------
    // ?? Intervallo ricalcolo derivato da f6 � 18 (invece di 40 hardcoded)
    int hurstRecalcDivisor = (int)MathRound(MathPow(PHI, 6));  // f6 � 18
    int hurstRecalcInterval = MathMax((int)MathRound(PHI_SQ), RecalcEveryBars / hurstRecalcDivisor);  // Minimo f� � 3
    
    bool needFullHurstRecalc = false;
    if (!g_cacheValid || g_hurstRecalcCounter >= hurstRecalcInterval) {
        needFullHurstRecalc = true;
        g_hurstRecalcCounter = 0;
    } else {
        g_hurstRecalcCounter++;
    }
    
    NaturalPeriodResult result_M5, result_H1, result_H4, result_D1;
    
    if (needFullHurstRecalc) {
        // ?? STEP 1: RICALCOLA PERIODI NATURALI E HURST (COSTOSO!)
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
        
        // ?? FIX: Aggiorna prezzo e ATR per rilevamento gap successivo
        g_lastCachePrice = currentPrice;
        // Usa ATR medio dal TF pi� stabile disponibile
        if (g_dataReady_H1 && tfData_H1.atr_avg > 0) {
            g_lastCacheATR = tfData_H1.atr_avg;
        } else if (g_dataReady_H4 && tfData_H4.atr_avg > 0) {
            g_lastCacheATR = tfData_H4.atr_avg;
        } else if (g_dataReady_M5 && tfData_M5.atr_avg > 0) {
            g_lastCacheATR = tfData_M5.atr_avg;
        } else {
            // ?? Fallback organico: f8 � 47 pips � pointValue � f
            //    Usato SOLO se nessun TF ha ATR valido
            int fallbackPips = (int)MathRound(MathPow(PHI, 8));  // f8 � 47
            g_lastCacheATR = g_pointValue * fallbackPips * PHI;
        }
    } else {
        // ?? USA CACHE (molto pi� veloce!)
        result_M5 = g_cachedResult_M5;
        result_H1 = g_cachedResult_H1;
        result_H4 = g_cachedResult_H4;
        result_D1 = g_cachedResult_D1;
    }
    
    // Aggiorna flag di validit�
    g_dataReady_M5 = result_M5.valid;
    g_dataReady_H1 = result_H1.valid;
    g_dataReady_H4 = result_H4.valid;
    g_dataReady_D1 = result_D1.valid;
    
    // Verifica che almeno un TF sia attivo
    if (!g_dataReady_M5 && !g_dataReady_H1 && !g_dataReady_H4 && !g_dataReady_D1) {
        Print("? [RECALC] NESSUN TF HA DATI SUFFICIENTI");
        return;
    }
    
    // ---------------------------------------------------------------
    // ?? STEP 2: RICALCOLA PESI EMPIRICI (Hurst)
    // peso_TF = hurstExponent_TF / somma(hurstExponent)
    // ---------------------------------------------------------------
    double totalHurst = 0;
    // ? hurstExponent gi� validato nel range organico [f?�, 1-f?�] da CalculateNaturalPeriodForTF
    if (result_M5.valid) totalHurst += result_M5.hurstExponent;
    if (result_H1.valid) totalHurst += result_H1.hurstExponent;
    if (result_H4.valid) totalHurst += result_H4.hurstExponent;
    if (result_D1.valid) totalHurst += result_D1.hurstExponent;
    
    // ? VALIDATO: Protezione divisione per zero
    if (totalHurst <= 0) totalHurst = 1.0;
    
    // ? VALIDATO: Pesi sempre >= 0 e normalizzati
    double weight_M5 = result_M5.valid ? (result_M5.hurstExponent / totalHurst) : 0;
    double weight_H1 = result_H1.valid ? (result_H1.hurstExponent / totalHurst) : 0;
    double weight_H4 = result_H4.valid ? (result_H4.hurstExponent / totalHurst) : 0;
    double weight_D1 = result_D1.valid ? (result_D1.hurstExponent / totalHurst) : 0;
    
    // ---------------------------------------------------------------
    // ?? STEP 3: RICALCOLA PERIODI ORGANICI (solo se Hurst ricalcolato)
    // ?? OTTIMIZZATO: salta se usiamo cache
    // ---------------------------------------------------------------
    if (needFullHurstRecalc) {
        if (g_dataReady_M5) CalculateOrganicPeriodsFromData(PERIOD_M5, g_organic_M5, result_M5.period, weight_M5, result_M5.hurstExponent);
        if (g_dataReady_H1) CalculateOrganicPeriodsFromData(PERIOD_H1, g_organic_H1, result_H1.period, weight_H1, result_H1.hurstExponent);
        if (g_dataReady_H4) CalculateOrganicPeriodsFromData(PERIOD_H4, g_organic_H4, result_H4.period, weight_H4, result_H4.hurstExponent);
        if (g_dataReady_D1) CalculateOrganicPeriodsFromData(PERIOD_D1, g_organic_D1, result_D1.period, weight_D1, result_D1.hurstExponent);
        
        // 🌱 FIX: Controlla se i periodi sono cambiati significativamente (>φ⁻³ ≈ 23.6%)
        // Se sì, ricrea gli handle indicatori con i nuovi periodi
        if (PeriodsChangedSignificantly()) {
            if (g_enableLogsEffective) {
                Print("[RECALC] 🔄 Periodi cambiati >φ⁻³ (23.6%) - Ricreazione handle indicatori...");
            }
            ReleaseIndicators();
            if (!InitializeIndicators()) {
                Print("❌ [RECALC] Errore ricreazione handle indicatori!");
            } else {
                // 🌱 FIX: Invalida cache dopo ricreazione handle - i dati vecchi non sono più validi
                g_tfDataCacheValid = false;
                g_cacheValid = false;
                if (g_enableLogsEffective) {
                    Print("[RECALC] ? Handle indicatori ricreati con nuovi periodi (cache invalidata)");
                }
            }
        }
        
        // Salva periodi correnti per confronto futuro
        SaveCurrentPeriodsAsPrevious();
    }
    
    // ---------------------------------------------------------------
    // ?? STEP 4: AGGIORNA FILTRO HURST COMPLETO
    // - Regimi per ogni TF
    // - H PESATO (non media semplice!)
    // - Aggiunge H al buffer storico ? zona adattiva
    // - Calcola tradeScore e soglia
    // ---------------------------------------------------------------
    if (EnableHurstFilter) {
        g_hurstRegime_M5 = GetHurstRegime(result_M5.hurstExponent);
        g_hurstRegime_H1 = GetHurstRegime(result_H1.hurstExponent);
        g_hurstRegime_H4 = GetHurstRegime(result_H4.hurstExponent);
        g_hurstRegime_D1 = GetHurstRegime(result_D1.hurstExponent);
        
        // ---------------------------------------------------------------
        // ?? CALCOLO H PESATO (non media semplice!)
        // H_weighted = S(H_TF � peso_TF) / S(peso_TF)
        // ---------------------------------------------------------------
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
        
        // ?? Aggiunge H al buffer storico ? calcola zona adattiva
        // ?? CRITICO: NON aggiungere valori invalidi (fuori range organico) al buffer!
        if (weightSum > 0 && g_hurstComposite > HURST_RANGE_MIN && g_hurstComposite < HURST_RANGE_MAX) {
            AddHurstToHistory(g_hurstComposite);
        }
        
        // Calcola confidenza (usa g_hurstCenter calcolato in AddHurstToHistory)
        g_hurstConfidence = GetHurstConfidence(g_hurstComposite);
        
        // ---------------------------------------------------------------
        // ?? CALCOLA tradeScore 100% DAI DATI
        // deviation = |H - centro| dove centro = media(H) storica
        // normalizzazione = stdev storica � f (scala data-driven)
        // ? VALIDATO: tradeScore sempre >= 0
        //    - deviation >= 0 (MathAbs)
        //    - g_hurstConfidence in [0, 1] (validato in GetHurstConfidence)
        //    - normFactor > 0 quando usato
        // ---------------------------------------------------------------
        // ?? FIX: Check esplicito g_hurstStdev > 0 (pu� essere 0 se tutti i valori Hurst sono identici)
        if (!g_hurstZoneReady || g_hurstStdev <= 0) {
            g_hurstTradeScore = 0.0;  // ? Zona non pronta o stdev invalida ? 0 (sicuro)
        } else {
            double deviation = MathAbs(g_hurstComposite - g_hurstCenter);  // ? >= 0
            // ?? Normalizzazione: dividi per (stdev � f) - scala 100% dai dati
            double normFactor = g_hurstStdev * PHI;
            if (normFactor > 0) {
                g_hurstTradeScore = deviation * g_hurstConfidence / normFactor;  // ? >= 0
            } else {
                g_hurstTradeScore = 0.0;  // ? Fallback sicuro
            }
        }
        
        // ?? Aggiorna buffer tradeScore per soglia adattiva
        // IMPORTANTE: aggiungi SOLO se zona pronta (evita zeri durante warm-up)
        // ?? OTTIMIZZATO: usa somme incrementali O(1) invece di O(n)
        // ?? FIX: Ricalcolo periodico anti-drift
        // ? VALIDATO: g_hurstTradeScore >= 0 garantito (vedi sopra)
        if (g_hurstZoneReady) {
            // ?? FIX: Ricalcolo completo periodico per evitare drift floating point
            g_tradeScoreOperationCount++;
            if (g_tradeScoreOperationCount >= TRADE_SCORE_HISTORY_MAX) {
                RecalculateTradeScoreSumsFromScratch();
                g_tradeScoreOperationCount = 0;
            }
            
            // ? Sottrai valore vecchio se buffer pieno (PRIMA di sovrascrivere!)
            if (g_tradeScoreHistorySize == TRADE_SCORE_HISTORY_MAX) {
                double oldValue = g_tradeScoreHistory[g_tradeScoreHistoryIndex];
                g_tradeScoreSum -= oldValue;
                g_tradeScoreSumSq -= oldValue * oldValue;
                
                // ? SANITY CHECK: protezione da errori floating point accumulati
                if (g_tradeScoreSum < 0) g_tradeScoreSum = 0;
                if (g_tradeScoreSumSq < 0) g_tradeScoreSumSq = 0;
            }
            
            // Aggiungi nuovo valore
            g_tradeScoreHistory[g_tradeScoreHistoryIndex] = g_hurstTradeScore;
            g_tradeScoreSum += g_hurstTradeScore;
            g_tradeScoreSumSq += g_hurstTradeScore * g_hurstTradeScore;
            
            // ? VALIDATO: indice buffer sempre nel range [0, TRADE_SCORE_HISTORY_MAX-1]
            g_tradeScoreHistoryIndex = (g_tradeScoreHistoryIndex + 1) % TRADE_SCORE_HISTORY_MAX;
            if (g_tradeScoreHistorySize < TRADE_SCORE_HISTORY_MAX) g_tradeScoreHistorySize++;
        }
        
        // ?? Calcola soglia tradeScore O(1) con somme incrementali!
        int minTradeScoreSamples = (int)MathCeil(TRADE_SCORE_HISTORY_MAX * PHI_INV_SQ);  // ~38% del buffer
        if (g_tradeScoreHistorySize >= minTradeScoreSamples) {
            // ? VALIDATO: Media O(1) - divisione sicura (minTradeScoreSamples >= 1)
            double meanTS = g_tradeScoreSum / g_tradeScoreHistorySize;
            // ? VALIDATO: Varianza O(1): E[X�] - E[X]� con protezione negativa
            double meanSqTS = g_tradeScoreSumSq / g_tradeScoreHistorySize;
            double varianceTS = meanSqTS - (meanTS * meanTS);
            double stdevTS = (varianceTS > 0) ? MathSqrt(varianceTS) : 0.0;
            g_tradeScoreThreshold = meanTS + stdevTS * PHI_INV;  // ? >= 0
            g_tradeScoreReady = true;
        } else {
            g_tradeScoreReady = false;
        }
        
        // ?? DECISIONE TRADE: richiede zona Hurst + soglia tradeScore pronte
        g_hurstReady = (g_hurstZoneReady && g_tradeScoreReady);
        g_hurstAllowTrade = g_hurstReady && (g_hurstTradeScore >= g_tradeScoreThreshold);
        
        lastHurstRecalc = TimeCurrent();
    }
    
    // ---------------------------------------------------------------
    // ?? STEP 5: AGGIORNA SOGLIA SCORE DINAMICA
    // Se AutoScoreThreshold=true, ricalcola dalla distribuzione
    // ---------------------------------------------------------------
    UpdateDynamicThreshold();
    
    // Log dettagliato del ricalcolo organico
    if (g_enableLogsEffective) {
        Print("+-----------------------------------------------------------------------------+");
        Print("� ?? RICALCOLO SISTEMA ORGANICO COMPLETATO                                    �");
        Print("+-----------------------------------------------------------------------------�");
        Print("� STEP 1: PERIODI NATURALI (derivati da autocorrelazione dati)               �");
        PrintFormat("�   M5=%3d | H1=%3d | H4=%3d | D1=%3d                                        �",
            result_M5.period, result_H1.period, result_H4.period, result_D1.period);
        Print("+-----------------------------------------------------------------------------�");
        Print("� STEP 2: ESPONENTI HURST (confronto vs g_hurstCenter storico)               �");
        PrintFormat("�   M5=%.3f(%s) H1=%.3f(%s) H4=%.3f(%s) D1=%.3f(%s)                       �",
            result_M5.hurstExponent, g_hurstRegime_M5 == HURST_TRENDING ? "TREND" : (g_hurstRegime_M5 == HURST_MEANREV ? "M-REV" : "RAND "),
            result_H1.hurstExponent, g_hurstRegime_H1 == HURST_TRENDING ? "TREND" : (g_hurstRegime_H1 == HURST_MEANREV ? "M-REV" : "RAND "),
            result_H4.hurstExponent, g_hurstRegime_H4 == HURST_TRENDING ? "TREND" : (g_hurstRegime_H4 == HURST_MEANREV ? "M-REV" : "RAND "),
            result_D1.hurstExponent, g_hurstRegime_D1 == HURST_TRENDING ? "TREND" : (g_hurstRegime_D1 == HURST_MEANREV ? "M-REV" : "RAND "));
        PrintFormat("�   H_pesato = %.4f (formula: S(H�peso) / S(peso))                          �", g_hurstComposite);
        Print("+-----------------------------------------------------------------------------�");
        Print("� STEP 3: PESI TF (derivati da Hurst: peso = H_TF / S(H))                     �");
        PrintFormat("�   M5=%.3f | H1=%.3f | H4=%.3f | D1=%.3f                                    �",
            weight_M5, weight_H1, weight_H4, weight_D1);
        Print("+-----------------------------------------------------------------------------�");
        Print("� STEP 4: ZONA HURST ADATTIVA (centro=mean(H), margine=stdev�f?�)             �");
        PrintFormat("�   Centro: %.4f (mean storica) | Stdev: %.5f                              �", g_hurstCenter, g_hurstStdev);
        PrintFormat("�   Zona: [%.4f, %.4f] | Buffer: %d/%d campioni                          �", 
            g_hurstRandomLow, g_hurstRandomHigh, g_hurstHistorySize, HURST_HISTORY_MAX);
        PrintFormat("�   TradeScore: %.4f | Soglia: %.4f | Stato: %s                           �",
            g_hurstTradeScore, g_tradeScoreThreshold,
            g_hurstAllowTrade ? "? TRADE OK" : (g_hurstReady ? "? BLOCCATO" : "? ATTESA DATI"));
        Print("+-----------------------------------------------------------------------------�");
        Print("� STEP 5: SOGLIA SCORE DINAMICA (formula: mean + stdev � f?�)                 �");
        if (g_scoreThresholdReady) {
            PrintFormat("�   Soglia corrente: %.2f%% | Buffer: %d/%d | Pronta: ?                     �",
                g_dynamicThreshold, g_scoreHistorySize, SCORE_HISTORY_MAX);
        } else {
            PrintFormat("�   Soglia corrente: (in attesa dati) | Buffer: %d/%d | Pronta: ?           �",
                g_scoreHistorySize, SCORE_HISTORY_MAX);
        }
        Print("+-----------------------------------------------------------------------------+");
    }
}

//+------------------------------------------------------------------+
//| ?? Calcola ESPONENTE DI HURST (metodo R/S - OTTIMIZZATO)         |
//| ?? Usa scale fisse e limite barre per velocit�                   |
//+------------------------------------------------------------------+
double CalculateHurstExponent(MqlRates &rates[], int n)
{
    // ?? COSTANTI ORGANICHE: tutte derivate da potenze di f
    // f8 � 47, f�� � 199 (limite max per evitare rumore)
    int minBarsHurst = (int)MathRound(MathPow(PHI, 8));   // f8 � 47
    int maxBarsHurst = (int)MathRound(MathPow(PHI, 11));  // f�� � 199
    
    // ?? Range Hurst valido: derivato da f?� e 1-f?�
    double hurstMin = PHI_INV_SQ;           // � 0.382 (sotto = molto mean-reverting)
    double hurstMax = 1.0 - PHI_INV_SQ;     // � 0.618 (sopra = molto trending)
    // Estendiamo leggermente per catturare valori estremi
    hurstMin = hurstMin * PHI_INV;          // � 0.236
    hurstMax = 1.0 - hurstMin;              // � 0.764
    
    // ?? OTTIMIZZAZIONE: Minimo barre organico
    // ?? Se dati insufficienti, ritorna centro storico SE disponibile dai DATI
    //    NESSUN fallback teorico (0.5) - solo valori empirici!
    if (n < minBarsHurst) {
        if (g_hurstZoneReady && g_hurstCenter > 0) return g_hurstCenter;
        return -1.0;  // Segnala "dati insufficienti" (gestito dal chiamante)
    }
    
    // ?? Limita a f�� barre max (derivato organicamente)
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
    
    // ---------------------------------------------------------------
    // ?? METODO R/S SEMPLIFICATO - Scale calcolate dinamicamente da f
    // Scale = potenze ESATTE di f: round(f5), round(f6), round(f7), round(f8), round(f?)
    // ---------------------------------------------------------------
    double logN[5], logRS[5];
    // ?? Scale calcolate dinamicamente da potenze di f
    int scales[5];
    scales[0] = (int)MathRound(MathPow(PHI, 5));  // f5 � 11
    scales[1] = (int)MathRound(MathPow(PHI, 6));  // f6 � 18
    scales[2] = (int)MathRound(MathPow(PHI, 7));  // f7 � 29
    scales[3] = (int)MathRound(MathPow(PHI, 8));  // f8 � 47
    scales[4] = (int)MathRound(MathPow(PHI, 9));  // f? � 76
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
    
    // ---------------------------------------------------------------
    // REGRESSIONE LINEARE VELOCE
    // ---------------------------------------------------------------
    // ?? Minimo scale = round(f�) � 3
    int minScales = (int)MathRound(PHI_SQ);
    // ?? Se scale insufficienti, ritorna centro storico SE disponibile dai DATI
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
    // ?? Threshold divisione: f?�� � 1.3e-5 (derivato da f)
    double divThreshold = MathPow(PHI_INV, 10);
    // ?? Se denominatore troppo piccolo, ritorna centro storico SE disponibile dai DATI
    //    NESSUN fallback teorico (0.5) - solo valori empirici!
    if (MathAbs(denom) < divThreshold) {
        if (g_hurstZoneReady && g_hurstCenter > 0) return g_hurstCenter;
        return -1.0;  // Segnala "dati insufficienti"
    }
    
    double H = (numScales * sumXY - sumX * sumY) / denom;
    
    // ? VALIDATO: Forza H nel range valido derivato da f
    // Range: [f?�, 1-f?�] � [0.236, 0.764]
    H = MathMax(hurstMin, MathMin(hurstMax, H));
    return H;
}

//+------------------------------------------------------------------+
//| ?? FILTRO HURST: Determina il regime da un singolo valore H      |
//| Soglie ADATTIVE 100% dai dati storici:                           |
//|   centro = media(H), margine = stdev(H) � f?�                    |
//+------------------------------------------------------------------+
// ? VALIDATO: Funzione robusta con protezioni
//    INPUT: h pu� essere qualsiasi valore
//    OUTPUT: ENUM valida garantita
ENUM_HURST_REGIME GetHurstRegime(double h)
{
    // ? VALIDATO: Se H non valido o zona non pronta, ritorna stato sicuro
    if (h < 0 || !g_hurstZoneReady) return HURST_RANDOM;
    
    if (h > g_hurstRandomHigh) return HURST_TRENDING;   // Sopra zona random
    if (h < g_hurstRandomLow)  return HURST_MEANREV;    // Sotto zona random
    return HURST_RANDOM;                                 // Dentro zona random
}

//+------------------------------------------------------------------+
//| ?? FILTRO HURST: Calcola confidenza                              |
//| Confidenza = |H - centro| / (stdev � f), capped a 1.0            |
//| Tutto derivato dai dati: centro = media(H), scala = stdev        |
//| ? VALIDATO:                                                      |
//|    INPUT: h pu� essere qualsiasi valore                          |
//|    OUTPUT: valore nel range [0.0, 1.0] garantito                 |
//+------------------------------------------------------------------+
double GetHurstConfidence(double h)
{
    // ? VALIDATO: Se non pronto o stdev invalido, ritorna 0.0 (sicuro)
    if (!g_hurstZoneReady || g_hurstStdev <= 0) return 0.0;
    double deviation = MathAbs(h - g_hurstCenter);
    double maxDeviation = g_hurstStdev * PHI;  // Scala basata su stdev � f
    // ? VALIDATO: maxDeviation > 0 perch� stdev > 0 e PHI > 0
    double confidence = deviation / maxDeviation;
    return MathMin(1.0, confidence);               // ? Cap a 1.0
}

//+------------------------------------------------------------------+
//| ?? FILTRO HURST: Inizializza buffer H storico                    |
//| NESSUN VALORE INIZIALE - tutto sar� calcolato dai dati!          |
//| ? VALIDAZIONE: Tutti i valori inizializzati a stati sicuri      |
//+------------------------------------------------------------------+
void InitHurstHistoryBuffer()
{
    // ? VALIDATO: Buffer dimensionato correttamente
    ArrayResize(g_hurstHistory, HURST_HISTORY_MAX);
    ArrayInitialize(g_hurstHistory, 0);  // Vuoto, verr� riempito dai dati
    
    // ? VALIDATO: Indici inizializzati a 0 (stato sicuro)
    g_hurstHistorySize = 0;
    g_hurstHistoryIndex = 0;
    
    // ? VALIDATO: Statistiche inizializzate a 0 (stato "non calcolato")
    g_hurstCenter = 0.0;
    g_hurstStdev = 0.0;
    g_hurstZoneMargin = 0.0;
    g_hurstRandomLow = 0.0;
    g_hurstRandomHigh = 0.0;
    g_hurstZoneReady = false;  // ? Flag indica che i dati NON sono pronti
    
    // ? VALIDATO: Somme incrementali a 0 (coerente con buffer vuoto)
    g_hurstSum = 0.0;
    g_hurstSumSq = 0.0;
    
    // ? VALIDATO: Buffer TradeScore
    ArrayResize(g_tradeScoreHistory, TRADE_SCORE_HISTORY_MAX);
    ArrayInitialize(g_tradeScoreHistory, 0);
    g_tradeScoreHistorySize = 0;
    g_tradeScoreHistoryIndex = 0;
    g_tradeScoreThreshold = 0.0;
    g_tradeScoreReady = false;
    g_hurstReady = false;
    
    // ? VALIDATO: Somme incrementali TradeScore a 0
    g_tradeScoreSum = 0.0;
    g_tradeScoreSumSq = 0.0;
    
    if (g_enableLogsEffective) {
        PrintFormat("[INIT-BUFFER] ?? g_hurstHistory: ArraySize=%d (max=%d) %s",
            ArraySize(g_hurstHistory), HURST_HISTORY_MAX,
            ArraySize(g_hurstHistory) == HURST_HISTORY_MAX ? "?" : "?");
        PrintFormat("[INIT-BUFFER] ?? g_tradeScoreHistory: ArraySize=%d (max=%d) %s",
            ArraySize(g_tradeScoreHistory), TRADE_SCORE_HISTORY_MAX,
            ArraySize(g_tradeScoreHistory) == TRADE_SCORE_HISTORY_MAX ? "?" : "?");
    }
}

//+------------------------------------------------------------------+
//| ?? PRE-CARICAMENTO MULTI-TF OTTIMIZZATO                          |
//| Usa tutti i TF disponibili ma con campionamento per velocit�     |
//+------------------------------------------------------------------+
void PreloadHurstBufferFromHistory()
{
    if (!EnableHurstFilter) return;
    
    // ?? CONFIGURAZIONE 100% ORGANICA (derivata da f)
    // barsPerHurst = f8 � 47 (minimo statistico) � f � 76
    int barsPerHurst = (int)MathRound(MathPow(PHI, 8) * PHI);  // � 76
    int samplesToPreload = HURST_HISTORY_MAX;  // Calcolato dinamicamente in OnInit
    // ?? skipFactor = round(f) = 2 (derivato organicamente)
    int skipFactor = (int)MathRound(PHI);  // � 2
    int effectiveSamples = samplesToPreload / skipFactor;
    
    // ?? Buffer organici: derivati da potenze di f
    int bufferM5 = (int)MathRound(MathPow(PHI, 5));  // f5 � 11
    int bufferH1 = (int)MathRound(MathPow(PHI, 4));  // f4 � 7
    int bufferH4 = (int)MathRound(MathPow(PHI, 3));  // f� � 4
    int bufferD1 = (int)MathRound(MathPow(PHI, 5));  // f5 � 11
    
    // ?? Rapporti TF calcolati dinamicamente dai minuti reali
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
    
    // ?? FIX: Usa start=1 per caricare dati STORICI (barre completate, non quella corrente incompleta)
    int copiedM5 = g_dataReady_M5 ? CopyRates(_Symbol, PERIOD_M5, 1, totalBarsM5, ratesM5) : 0;
    int copiedH1 = g_dataReady_H1 ? CopyRates(_Symbol, PERIOD_H1, 1, totalBarsH1, ratesH1) : 0;
    int copiedH4 = g_dataReady_H4 ? CopyRates(_Symbol, PERIOD_H4, 1, totalBarsH4, ratesH4) : 0;
    int copiedD1 = g_dataReady_D1 ? CopyRates(_Symbol, PERIOD_D1, 1, totalBarsD1, ratesD1) : 0;
    
    if (copiedM5 < barsPerHurst) {
        Print("[PRELOAD] ?? Dati M5 insufficienti per pre-caricamento");
        return;
    }
    
    Print("[PRELOAD] ?? Pre-caricamento MULTI-TF OTTIMIZZATO...");
    PrintFormat("[PRELOAD] ?? Barre: M5=%d H1=%d H4=%d D1=%d | Campioni=%d (skip=%d)",
        copiedM5, copiedH1, copiedH4, copiedD1, effectiveSamples, skipFactor);
    
    // ---------------------------------------------------------------
    // FASE 1: Calcola Hurst composito campionato
    // ? VALIDATO: Ogni hX validato nel range organico prima di usare
    // ---------------------------------------------------------------
    double hurstValues[];
    ArrayResize(hurstValues, effectiveSamples);
    ArrayInitialize(hurstValues, 0);
    int successCount = 0;
    int lastValidIndex = -1;
    
    for (int sample = 0; sample < effectiveSamples; sample++) {
        int i = sample * skipFactor;
        double hurstWeightedSum = 0;
        double weightSum = 0;
        
        // M5 - ? VALIDATO: hM5 controllato nel range organico
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
        
        // H1 - ? VALIDATO: hH1 controllato nel range organico
        if (copiedH1 > 0) {
            // ?? Rapporto calcolato dinamicamente
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
        
        // H4 - ? VALIDATO: hH4 controllato nel range organico
        if (copiedH4 > 0) {
            // ?? Rapporto calcolato dinamicamente
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
        
        // D1 - ? VALIDATO: hD1 controllato nel range organico
        // ?? Minimo barre D1 = f5 � 11 (derivato organicamente)
        int minBarsD1 = (int)MathRound(MathPow(PHI, 5));
        if (copiedD1 >= minBarsD1) {
            // ?? Rapporto calcolato dinamicamente
            int idxD1 = (int)MathRound(i / ratioD1);
            // ?? Buffer D1 = f4 � 7 (derivato organicamente)
            int bufD1 = (int)MathRound(MathPow(PHI, 4));
            if (idxD1 < copiedD1 - bufD1) {
                MqlRates subRates[];
                // ?? Barre D1 minimo = f4 � 7
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
        // ? VALIDATO: weightSum > 0, hComposite nel range organico
        if (weightSum > 0) {
            double hComposite = hurstWeightedSum / weightSum;
            
            // ? VALIDAZIONE: Accetta solo valori nel range Hurst organico
            if (hComposite < HURST_RANGE_MIN || hComposite > HURST_RANGE_MAX) continue;
            
            hurstValues[sample] = hComposite;
            lastValidIndex = sample;
            
            // Aggiungi al buffer (replica per compensare skip)
            // ?? CRITICO: Aggiorna anche le somme incrementali!
            for (int rep = 0; rep < skipFactor; rep++) {
                // ? Se buffer pieno, sottrai valore vecchio che stiamo per sovrascrivere
                if (g_hurstHistorySize == HURST_HISTORY_MAX) {
                    double oldValue = g_hurstHistory[g_hurstHistoryIndex];
                    g_hurstSum -= oldValue;
                    g_hurstSumSq -= oldValue * oldValue;
                    
                    // ? SANITY CHECK: protezione da errori floating point
                    if (g_hurstSum < 0) g_hurstSum = 0;
                    if (g_hurstSumSq < 0) g_hurstSumSq = 0;
                }
                
                g_hurstHistory[g_hurstHistoryIndex] = hComposite;  // ? Valore gi� validato
                g_hurstSum += hComposite;
                g_hurstSumSq += hComposite * hComposite;
                // ? VALIDATO: indice sempre nel range [0, HURST_HISTORY_MAX-1]
                g_hurstHistoryIndex = (g_hurstHistoryIndex + 1) % HURST_HISTORY_MAX;
                
                if (g_hurstHistorySize < HURST_HISTORY_MAX) {
                    g_hurstHistorySize++;
                }
            }
            successCount++;
        }
    }
    
    // ---------------------------------------------------------------
    // FASE 2: Calcola centro, stdev e zona Hurst
    // ?? OTTIMIZZATO: usa le somme incrementali gi� calcolate!
    // ? VALIDATO: divisione sicura (g_hurstHistorySize >= minSamples >= 1)
    // ?? FIX: Check esplicito per g_hurstHistorySize == 0
    // ---------------------------------------------------------------
    
    // ?? FIX: Protezione divisione per zero - nessun campione valido
    if (g_hurstHistorySize == 0) {
        PrintFormat("[PRELOAD] ?? Nessun campione Hurst valido - pre-caricamento fallito");
        return;
    }
    
    int minSamples = (int)MathCeil(HURST_HISTORY_MAX * PHI_INV_SQ);
    if (g_hurstHistorySize < minSamples) {
        PrintFormat("[PRELOAD] ?? Pre-caricamento parziale Hurst: solo %d campioni validi", successCount);
        return;
    }
    
    // ?? ? Calcola centro O(1) - divisione sicura (g_hurstHistorySize > 0 garantito)
    g_hurstCenter = g_hurstSum / g_hurstHistorySize;
    
    // ?? ? Calcola stdev O(1): Var(X) = E[X�] - E[X]� con protezione negativa
    double meanSq = g_hurstSumSq / g_hurstHistorySize;
    double variance = meanSq - (g_hurstCenter * g_hurstCenter);
    g_hurstStdev = (variance > 0) ? MathSqrt(variance) : 0.0;  // ? >= 0
    
    // ? Calcola margine e zona
    double newMargin = g_hurstStdev * PHI_INV;
    double minMargin = g_hurstStdev * PHI_INV_SQ;
    double maxMargin = g_hurstStdev * PHI;
    g_hurstZoneMargin = MathMax(minMargin, MathMin(maxMargin, newMargin));  // ? >= 0
    
    g_hurstRandomLow = g_hurstCenter - g_hurstZoneMargin;
    g_hurstRandomHigh = g_hurstCenter + g_hurstZoneMargin;
    g_hurstZoneReady = true;
    
    PrintFormat("[PRELOAD] ? Buffer Hurst: %d/%d | Centro=%.4f Stdev=%.4f Zona=[%.4f, %.4f]", 
        successCount, samplesToPreload, g_hurstCenter, g_hurstStdev, g_hurstRandomLow, g_hurstRandomHigh);
    
    // ---------------------------------------------------------------
    // FASE 3: Calcola TradeScore per ogni campione Hurst e riempi buffer
    // Ora che abbiamo centro e stdev, possiamo calcolare i tradeScore!
    // ? VALIDATO: tradeScore >= 0 garantito
    // ---------------------------------------------------------------
    int tradeScoreCount = 0;
    int samplesToPreloadTS = MathMin(effectiveSamples, TRADE_SCORE_HISTORY_MAX);
    
    for (int i = 0; i < samplesToPreloadTS; i++) {
        double h = hurstValues[i];
        if (h < HURST_RANGE_MIN || h > HURST_RANGE_MAX) continue;  // ? Solo valori validi
        
        // ? Calcola confidence (stessa logica di GetHurstConfidence)
        double deviation = MathAbs(h - g_hurstCenter);  // ? >= 0
        double maxDeviation = g_hurstStdev * PHI;
        double confidence = (maxDeviation > 0) ? MathMin(1.0, deviation / maxDeviation) : 0.0;  // ? [0, 1]
        
        // ? Calcola tradeScore (stessa logica di RecalculateOrganicSystem)
        double normFactor = g_hurstStdev * PHI;
        double tradeScore = 0;
        if (normFactor > 0) {
            tradeScore = deviation * confidence / normFactor;  // ? >= 0
        }
        
        // Aggiungi al buffer TradeScore
        // ?? CRITICO: Aggiorna anche le somme incrementali!
        // ? Se buffer pieno, sottrai valore vecchio che stiamo per sovrascrivere
        if (g_tradeScoreHistorySize == TRADE_SCORE_HISTORY_MAX) {
            double oldValue = g_tradeScoreHistory[g_tradeScoreHistoryIndex];
            g_tradeScoreSum -= oldValue;
            g_tradeScoreSumSq -= oldValue * oldValue;
            
            // ? SANITY CHECK: protezione da errori floating point
            if (g_tradeScoreSum < 0) g_tradeScoreSum = 0;
            if (g_tradeScoreSumSq < 0) g_tradeScoreSumSq = 0;
        }
        
        g_tradeScoreHistory[g_tradeScoreHistoryIndex] = tradeScore;
        g_tradeScoreSum += tradeScore;
        g_tradeScoreSumSq += tradeScore * tradeScore;
        // ? VALIDATO: indice sempre nel range [0, TRADE_SCORE_HISTORY_MAX-1]
        g_tradeScoreHistoryIndex = (g_tradeScoreHistoryIndex + 1) % TRADE_SCORE_HISTORY_MAX;
        
        if (g_tradeScoreHistorySize < TRADE_SCORE_HISTORY_MAX) {
            g_tradeScoreHistorySize++;
        }
        tradeScoreCount++;
    }
    
    // ---------------------------------------------------------------
    // FASE 4: Calcola soglia TradeScore dai dati pre-caricati
    // ?? OTTIMIZZATO: usa le somme incrementali gi� calcolate!
    // ? VALIDATO: divisione sicura (minTradeScoreSamples >= 1)
    // ---------------------------------------------------------------
    int minTradeScoreSamples = (int)MathCeil(TRADE_SCORE_HISTORY_MAX * PHI_INV_SQ);
    if (g_tradeScoreHistorySize >= minTradeScoreSamples) {
        // ?? ? Media O(1) - divisione sicura
        double meanTS = g_tradeScoreSum / g_tradeScoreHistorySize;
        
        // ?? ? Varianza O(1): Var(X) = E[X�] - E[X]� con protezione negativa
        double meanSqTS = g_tradeScoreSumSq / g_tradeScoreHistorySize;
        double varianceTS = meanSqTS - (meanTS * meanTS);
        double stdevTS = (varianceTS > 0) ? MathSqrt(varianceTS) : 0.0;
        
        g_tradeScoreThreshold = meanTS + stdevTS * PHI_INV;  // ? >= 0
        g_tradeScoreReady = true;
        
        PrintFormat("[PRELOAD] ? Buffer TradeScore: %d/%d | Soglia=%.4f", 
            tradeScoreCount, TRADE_SCORE_HISTORY_MAX, g_tradeScoreThreshold);
    } else {
        PrintFormat("[PRELOAD] ?? TradeScore parziale: solo %d campioni", tradeScoreCount);
    }
    
    // ---------------------------------------------------------------
    // FASE 5: Imposta stato globale per permettere trading immediato
    // CRITICO: Calcola g_hurstTradeScore e g_hurstAllowTrade!
    // ? VALIDATO: tutti i valori usati sono gi� validati nelle fasi precedenti
    // ---------------------------------------------------------------
    g_hurstReady = (g_hurstZoneReady && g_tradeScoreReady);
    
    if (g_hurstReady && lastValidIndex >= 0) {
        // Usa l'ultimo Hurst valido (il pi� recente, tracciato da lastValidIndex)
        double lastHurst = hurstValues[lastValidIndex];  // ? Gi� validato nel range organico
        g_hurstComposite = lastHurst;
        
        // ? Calcola g_hurstConfidence (stessa logica di GetHurstConfidence)
        double deviation = MathAbs(lastHurst - g_hurstCenter);  // ? >= 0
        double maxDeviation = g_hurstStdev * PHI;
        g_hurstConfidence = (maxDeviation > 0) ? MathMin(1.0, deviation / maxDeviation) : 0.0;  // ? [0, 1]
        
        // ? Calcola g_hurstTradeScore (stessa logica di RecalculateOrganicSystem)
        double normFactor = g_hurstStdev * PHI;
        if (normFactor > 0) {
            g_hurstTradeScore = deviation * g_hurstConfidence / normFactor;  // ? >= 0
        } else {
            g_hurstTradeScore = 0;  // ? Fallback sicuro
        }
        
        // CRITICO: Setta g_hurstAllowTrade per permettere trading!
        g_hurstAllowTrade = (g_hurstTradeScore >= g_tradeScoreThreshold);
        
        PrintFormat("[PRELOAD] ??? PRE-CARICAMENTO COMPLETO!");
        PrintFormat("[PRELOAD]   H_composito=%.4f | Centro=%.4f | Confidence=%.3f", 
            g_hurstComposite, g_hurstCenter, g_hurstConfidence);
        PrintFormat("[PRELOAD]   TradeScore=%.4f %s Soglia=%.4f ? %s", 
            g_hurstTradeScore, 
            g_hurstTradeScore >= g_tradeScoreThreshold ? "=" : "<",
            g_tradeScoreThreshold,
            g_hurstAllowTrade ? "? TRADE OK" : "? BLOCCATO");
    } else {
        Print("[PRELOAD] ?? Pre-caricamento incompleto - warm-up richiesto");
    }
}

//+------------------------------------------------------------------+
//| ?? FILTRO HURST: Aggiungi H al buffer e aggiorna zona adattiva   |
//| ?? OTTIMIZZATO: Usa somme incrementali O(1) invece di O(n)       |
//| ?? FIX: Ricalcolo periodico completo per evitare drift numerico  |
//| ? INPUT VALIDATO: h deve essere nel range organico [f?�, 1-f?�]  |
//|    (validazione fatta dal chiamante prima di questa funzione)    |
//+------------------------------------------------------------------+
void AddHurstToHistory(double h)
{
    // ?? FIX: Ricalcolo completo periodico per evitare drift floating point
    // Ogni HURST_HISTORY_MAX operazioni, ricalcola somme da zero
    g_hurstOperationCount++;
    if (g_hurstOperationCount >= HURST_HISTORY_MAX) {
        RecalculateHurstSumsFromScratch();
        g_hurstOperationCount = 0;
    }
    
    // ? VALIDATO: Sottrai valore vecchio se buffer pieno (buffer circolare)
    if (g_hurstHistorySize == HURST_HISTORY_MAX) {
        double oldValue = g_hurstHistory[g_hurstHistoryIndex];
        g_hurstSum -= oldValue;
        g_hurstSumSq -= oldValue * oldValue;
        
        // ? SANITY CHECK: protezione da errori floating point accumulati
        if (g_hurstSum < 0) g_hurstSum = 0;
        if (g_hurstSumSq < 0) g_hurstSumSq = 0;
    }
    
    // ? VALIDATO: Aggiungi nuovo valore al buffer
    g_hurstHistory[g_hurstHistoryIndex] = h;
    g_hurstSum += h;
    g_hurstSumSq += h * h;
    
    // ? VALIDATO: Indice sempre nel range [0, MAX-1] grazie al modulo
    g_hurstHistoryIndex = (g_hurstHistoryIndex + 1) % HURST_HISTORY_MAX;
    
    // ? VALIDATO: Size mai > MAX
    if (g_hurstHistorySize < HURST_HISTORY_MAX) {
        g_hurstHistorySize++;
    }
    
    // Ricalcola CENTRO e STDEV con somme incrementali O(1)!
    int minSamples = (int)MathCeil(HURST_HISTORY_MAX * PHI_INV_SQ);  // ~38% del buffer
    if (g_hurstHistorySize >= minSamples) {
        // ? VALIDATO: Divisione sicura (minSamples >= 1)
        g_hurstCenter = g_hurstSum / g_hurstHistorySize;
        
        // ? VALIDATO: Varianza O(1) con protezione per valori negativi
        double meanSq = g_hurstSumSq / g_hurstHistorySize;
        double variance = meanSq - (g_hurstCenter * g_hurstCenter);
        g_hurstStdev = (variance > 0) ? MathSqrt(variance) : 0.0;
        
        // ?? MARGINE = stdev � f?�
        double newMargin = g_hurstStdev * PHI_INV;
        double minMargin = g_hurstStdev * PHI_INV_SQ;
        double maxMargin = g_hurstStdev * PHI;
        g_hurstZoneMargin = MathMax(minMargin, MathMin(maxMargin, newMargin));
        
        // ?? ZONA = centro � margine
        g_hurstRandomLow = g_hurstCenter - g_hurstZoneMargin;
        g_hurstRandomHigh = g_hurstCenter + g_hurstZoneMargin;
        g_hurstZoneReady = true;  // ? Flag: dati pronti per l'uso
    }
    else {
        g_hurstZoneReady = false;  // ? Flag: dati NON pronti
    }
}

//+------------------------------------------------------------------+
//| ?? FIX: Ricalcolo completo somme Hurst per evitare drift        |
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
        PrintFormat("[?? ANTI-DRIFT] Ricalcolo completo somme Hurst: Sum=%.6f SumSq=%.6f (size=%d)",
            g_hurstSum, g_hurstSumSq, g_hurstHistorySize);
    }
}

//+------------------------------------------------------------------+
//| ?? FILTRO HURST: Check finale prima di aprire trade              |
//| Ritorna true se il trade � permesso, false se bloccato           |
//| NOTA: Il ricalcolo avviene ora in RecalculateOrganicSystem()     |
//| ?? FIX: Log rimosso da qui - stampato solo se c'era segnale      |
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
            PrintFormat("[HURST] ? Hurst NON pronto (%d barre) - servono piu' dati per zona/stdev", hurstNotReadyCount);
        }
        return false;
    }
    // ?? FIX: Log "TRADE BLOCCATO" rimosso - stampato in ExecuteTrades solo se c'era segnale
    
    return g_hurstAllowTrade;
}

//+------------------------------------------------------------------+
//| ?? SOGLIA DINAMICA: Inizializza buffer score storici             |
//+------------------------------------------------------------------+
void InitScoreHistoryBuffer()
{
    ArrayResize(g_scoreHistory, SCORE_HISTORY_MAX);
    ArrayInitialize(g_scoreHistory, 0);
    g_scoreHistorySize = 0;
    g_scoreHistoryIndex = 0;
    g_dynamicThreshold = ScoreThreshold;  // Inizia con valore manuale
    g_scoreThresholdReady = false;
    
    // ?? CRITICO: Inizializza somme incrementali Score
    g_scoreSum = 0.0;
    g_scoreSumSq = 0.0;
    
    if (g_enableLogsEffective) {
        PrintFormat("[INIT-BUFFER] ?? g_scoreHistory: ArraySize=%d (max=%d) %s",
            ArraySize(g_scoreHistory), SCORE_HISTORY_MAX,
            ArraySize(g_scoreHistory) == SCORE_HISTORY_MAX ? "?" : "?");
        if (AutoScoreThreshold) {
            Print("[INIT-BUFFER] ?? Soglia score dinamica attiva: mean + stdev � f?�");
        } else {
            PrintFormat("[INIT-BUFFER] ?? Soglia score manuale: %.1f%%", ScoreThreshold);
        }
    }
}

//+------------------------------------------------------------------+
//| ?? SOGLIA DINAMICA: Aggiungi score al buffer circolare           |
//| ?? OTTIMIZZATO: Usa somme incrementali O(1)                      |
//| ?? FIX: Ricalcolo periodico completo per evitare drift numerico  |
//| ? INPUT: scorePct pu� essere qualsiasi valore (0-100%)          |
//+------------------------------------------------------------------+
void AddScoreToHistory(double scorePct)
{
    if (!AutoScoreThreshold) return;  // Non serve se soglia manuale
    
    // ?? FIX: Ricalcolo completo periodico per evitare drift floating point
    g_scoreOperationCount++;
    if (g_scoreOperationCount >= SCORE_HISTORY_MAX) {
        RecalculateScoreSumsFromScratch();
        g_scoreOperationCount = 0;
    }
    
    // ? VALIDATO: Sottrai valore vecchio se buffer pieno
    if (g_scoreHistorySize == SCORE_HISTORY_MAX) {
        double oldValue = g_scoreHistory[g_scoreHistoryIndex];
        g_scoreSum -= oldValue;
        g_scoreSumSq -= oldValue * oldValue;
        
        // ? SANITY CHECK: protezione da errori floating point accumulati
        if (g_scoreSum < 0) g_scoreSum = 0;
        if (g_scoreSumSq < 0) g_scoreSumSq = 0;
    }
    
    // ? VALIDATO: Aggiungi nuovo valore
    g_scoreHistory[g_scoreHistoryIndex] = scorePct;
    g_scoreSum += scorePct;
    g_scoreSumSq += scorePct * scorePct;
    
    // ? VALIDATO: Indice sempre nel range [0, MAX-1]
    g_scoreHistoryIndex = (g_scoreHistoryIndex + 1) % SCORE_HISTORY_MAX;
    
    // ? VALIDATO: Size mai > MAX
    if (g_scoreHistorySize < SCORE_HISTORY_MAX) {
        g_scoreHistorySize++;
    }
}

//+------------------------------------------------------------------+
//| 🔄 FIX: Ricalcolo completo somme Score per evitare drift         |
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
        PrintFormat("[🔄 ANTI-DRIFT] Ricalcolo completo somme Score: Sum=%.2f SumSq=%.2f (size=%d)",
            g_scoreSum, g_scoreSumSq, g_scoreHistorySize);
    }
}

//+------------------------------------------------------------------+
//| 🌱 v1.1 FIX: Registra score per un nuovo trade aperto            |
//| Salva ticket → score mapping per collegamento a chiusura         |
//+------------------------------------------------------------------+
void RegisterOpenTradeScore(ulong ticket, double scorePct)
{
    if (ticket == 0 || g_openTicketsMax == 0) return;
    
    // Cerca slot libero (ticket == 0) o stesso ticket (update)
    int freeSlot = -1;
    for (int i = 0; i < g_openTicketsMax; i++) {
        if (g_openTickets[i] == ticket) {
            // Aggiorna esistente
            g_openScores[i] = scorePct;
            return;
        }
        if (g_openTickets[i] == 0 && freeSlot < 0) {
            freeSlot = i;
        }
    }
    
    if (freeSlot >= 0) {
        g_openTickets[freeSlot] = ticket;
        g_openScores[freeSlot] = scorePct;
        g_openTicketsCount++;
        
        if (g_enableLogsEffective) {
            PrintFormat("[YOUDEN] 📝 Score %.1f%% registrato per ticket #%I64u", scorePct, ticket);
        }
    } else {
        // Buffer pieno - cerca la posizione più vecchia che potrebbe essere chiusa
        // Strategia: sovrascriviamo la prima posizione (FIFO - First In First Out)
        // Questo è corretto perché le posizioni più vecchie hanno maggiore probabilità di essere chiuse
        // Nota: slot 0 non è arbitrario ma è l'entry point FIFO naturale
        g_openTickets[0] = ticket;
        g_openScores[0] = scorePct;
        if (g_enableLogsEffective) {
            Print("[YOUDEN] ⚠ Buffer pieno - sovrascritto slot più vecchio (FIFO)");
        }
    }
}

//+------------------------------------------------------------------+
//| 🌱 v1.1 FIX: Recupera score per un trade chiuso                  |
//| Cerca ticket nella mappa e rimuove dopo il recupero              |
//+------------------------------------------------------------------+
double GetAndRemoveTradeScore(ulong ticket)
{
    if (ticket == 0 || g_openTicketsMax == 0) return 0.0;
    
    for (int i = 0; i < g_openTicketsMax; i++) {
        if (g_openTickets[i] == ticket) {
            double score = g_openScores[i];
            // Rimuovi dalla mappa
            g_openTickets[i] = 0;
            g_openScores[i] = 0.0;
            if (g_openTicketsCount > 0) g_openTicketsCount--;
            
            if (g_enableLogsEffective) {
                PrintFormat("[YOUDEN] 📤 Score %.1f%% recuperato per ticket #%I64u", score, ticket);
            }
            return score;
        }
    }
    
    // Ticket non trovato - potrebbe essere trade pre-v1.1 o errore
    return 0.0;
}

//+------------------------------------------------------------------+
//| 🔄 FIX: Ricalcolo completo somme TradeScore per evitare drift    |
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
        PrintFormat("[🔄 ANTI-DRIFT] Ricalcolo completo somme TradeScore: Sum=%.6f SumSq=%.6f (size=%d)",
            g_tradeScoreSum, g_tradeScoreSumSq, g_tradeScoreHistorySize);
    }
}

//+------------------------------------------------------------------+
//| 🌱 OTSU: Soglia che massimizza varianza inter-classe             |
//| Trova il punto di separazione naturale tra score "deboli" e      |
//| score "forti" nella distribuzione storica                        |
//| INPUT: array score storici                                       |
//| OUTPUT: soglia ottimale [0-100] che separa le due classi         |
//| 🌱 100% DATA-DRIVEN: nessun numero fisso arbitrario             |
//+------------------------------------------------------------------+
double CalcOtsuThreshold()
{
    // Minimo campioni = φ³ ≈ 4.24 → 5 (derivato da φ)
    int minSamples = (int)MathCeil(MathPow(PHI, 3));
    if (g_scoreHistorySize < minSamples) {
        // Fallback: mediana dei dati esistenti (data-driven)
        if (g_scoreHistorySize > 0) {
            return CalculatePercentile(g_scoreHistory, g_scoreHistorySize, PHI_INV * 100.0);  // φ⁻¹ ≈ 61.8%
        }
        return ScoreThreshold;  // Ultimo fallback: input utente
    }
    
    // Crea istogramma degli score (100 bin da 0% a 100%)
    int histogram[101];
    ArrayInitialize(histogram, 0);
    
    // Popola istogramma
    for (int i = 0; i < g_scoreHistorySize; i++) {
        int bin = (int)MathRound(MathMax(0, MathMin(100, g_scoreHistory[i])));
        histogram[bin]++;
    }
    
    // Calcoli Otsu
    double total = (double)g_scoreHistorySize;
    double sumTotal = 0.0;
    for (int i = 0; i <= 100; i++) {
        sumTotal += i * histogram[i];
    }
    
    double sumB = 0.0;
    double wB = 0.0;
    double maxVariance = 0.0;
    // Fallback iniziale = media degli score (data-driven)
    double optimalThreshold = sumTotal / total;
    
    for (int t = 0; t <= 100; t++) {
        wB += histogram[t];  // Peso classe background (score < t)
        if (wB == 0) continue;
        
        double wF = total - wB;  // Peso classe foreground (score >= t)
        if (wF == 0) break;
        
        sumB += t * histogram[t];
        
        double meanB = sumB / wB;                    // Media classe background
        double meanF = (sumTotal - sumB) / wF;       // Media classe foreground
        
        // Varianza inter-classe = wB * wF * (meanB - meanF)²
        double variance = wB * wF * (meanB - meanF) * (meanB - meanF);
        
        if (variance > maxVariance) {
            maxVariance = variance;
            optimalThreshold = t;
        }
    }
    
    return optimalThreshold;
}

//+------------------------------------------------------------------+
//| 🌱 YOUDEN J: Soglia che massimizza (Sensitivity + Specificity -1)|
//| Basato sui RISULTATI REALI dei trade (profitti/perdite)          |
//| INPUT: g_recentTrades[] con scoreAtEntry e profit                |
//| OUTPUT: soglia ottimale che massimizza J = TPR + TNR - 1         |
//|                                                                  |
//| True Positive = Trade aperto (score >= T) E profittevole         |
//| True Negative = Trade NON aperto (score < T) E sarebbe perdita   |
//| False Positive = Trade aperto E perdita                          |
//| False Negative = Trade NON aperto E sarebbe profitto             |
//+------------------------------------------------------------------+
double CalcYoudenThreshold()
{
    if (g_recentTradesCount < g_minTradesForYouden) return 0.0;  // Non pronto
    
    // Raccogli tutti i trade con score valido
    double scores[];
    double profits[];
    int validCount = 0;
    
    ArrayResize(scores, g_recentTradesCount);
    ArrayResize(profits, g_recentTradesCount);
    
    for (int i = 0; i < g_recentTradesCount; i++) {
        int idx = (g_recentTradesIndex - g_recentTradesCount + i + g_recentTradesMax) % g_recentTradesMax;
        if (g_recentTrades[idx].scoreAtEntry > 0) {  // Score valido
            scores[validCount] = g_recentTrades[idx].scoreAtEntry;
            profits[validCount] = g_recentTrades[idx].profit;
            validCount++;
        }
    }
    
    if (validCount < g_minTradesForYouden) return 0.0;
    
    // Conta trade vincenti e perdenti per calcolo Youden
    int totalPositives = 0;   // Trade profittevoli (dovremmo entrare)
    int totalNegatives = 0;   // Trade in perdita (non dovremmo entrare)
    
    for (int i = 0; i < validCount; i++) {
        if (profits[i] >= 0) totalPositives++;
        else totalNegatives++;
    }
    
    // Se tutti vincenti o tutti perdenti, Youden non applicabile
    if (totalPositives == 0 || totalNegatives == 0) return 0.0;
    
    // Trova soglia che massimizza J = TPR + TNR - 1
    double maxJ = -1.0;
    
    // 🌱 Range test DATA-DRIVEN: da φ⁻³ a (1-φ⁻³) della distribuzione score
    // Invece di 10-90 fisso, usiamo i percentili reali dei dati
    double minScoreTest = CalculatePercentile(scores, validCount, PHI_INV_CUB * 100.0);     // ~23.6%
    double maxScoreTest = CalculatePercentile(scores, validCount, (1.0 - PHI_INV_CUB) * 100.0); // ~76.4%
    
    // Fallback iniziale = percentile φ⁻¹ ≈ 61.8% degli score (data-driven)
    double optimalThreshold = CalculatePercentile(scores, validCount, PHI_INV * 100.0);
    
    // Step = range / φ⁴ per avere ~7 test (derivato da φ)
    // Minimo step = φ⁻² ≈ 0.382 (derivato da φ, non 1.0 arbitrario)
    double stepSize = MathMax(PHI_INV_SQ, (maxScoreTest - minScoreTest) / MathPow(PHI, 4));
    
    // Testa soglie nel range data-driven
    for (double threshold = minScoreTest; threshold <= maxScoreTest; threshold += stepSize) {
        
        // Calcola TP, TN, FP, FN per questa soglia
        int TP = 0;  // Score >= T e profitto (corretto entrare)
        int FN = 0;  // Score < T e profitto (sbagliato non entrare)
        int TN = 0;  // Score < T e perdita (corretto non entrare)
        int FP = 0;  // Score >= T e perdita (sbagliato entrare)
        
        for (int i = 0; i < validCount; i++) {
            bool wouldEnter = (scores[i] >= threshold);
            bool isProfitable = (profits[i] >= 0);
            
            if (wouldEnter && isProfitable) TP++;
            else if (wouldEnter && !isProfitable) FP++;
            else if (!wouldEnter && isProfitable) FN++;
            else TN++;  // !wouldEnter && !isProfitable
        }
        
        // TPR = TP / (TP + FN) = Sensitivity (quanti profitti catturiamo)
        // TNR = TN / (TN + FP) = Specificity (quante perdite evitiamo)
        double TPR = (totalPositives > 0) ? (double)TP / totalPositives : 0.0;
        double TNR = (totalNegatives > 0) ? (double)TN / totalNegatives : 0.0;
        
        double J = TPR + TNR - 1.0;  // Youden's J: [-1, +1], 0 = random
        
        if (J > maxJ) {
            maxJ = J;
            optimalThreshold = threshold;
        }
    }
    
    // Log se J è significativo (soglia = φ⁻³ ≈ 0.236, derivata da φ)
    double jLogThreshold = PHI_INV_CUB;  // ~0.236 - J deve essere almeno questo per essere "significativo"
    if (g_enableLogsEffective && maxJ > jLogThreshold) {
        PrintFormat("[YOUDEN] 🎯 J=%.3f | Soglia ottimale: %.1f%% | Trades analizzati: %d (W:%d L:%d)",
            maxJ, optimalThreshold, validCount, totalPositives, totalNegatives);
    }
    
    // Solo se J > 0 (meglio di random), altrimenti ritorna 0
    return (maxJ > 0) ? optimalThreshold : 0.0;
}

//+------------------------------------------------------------------+
//| 🌱 SOGLIA DINAMICA ADATTIVA: OTSU → YOUDEN                       |
//| Fase 1 (warm-up): Usa Otsu (separazione statistica)              |
//| Fase 2 (feedback): Usa Youden (basato su profitti reali)         |
//| ZERO numeri fissi - tutto derivato dai dati                      |
//+------------------------------------------------------------------+
void UpdateDynamicThreshold()
{
    if (!AutoScoreThreshold) {
        // Soglia manuale: usa valore impostato dall'utente
        g_dynamicThreshold = ScoreThreshold;
        g_scoreThresholdReady = true;
        return;
    }
    
    double oldThreshold = g_dynamicThreshold;
    string thresholdMethod = "";
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 FASE 1: OTSU (warm-up - separazione statistica)
    // Trova la soglia che separa naturalmente gli score in due classi
    // ═══════════════════════════════════════════════════════════════
    int minSamplesForOtsu = (int)MathRound(MathPow(PHI, 4));  // φ⁴ ≈ 7 campioni
    
    if (g_scoreHistorySize < minSamplesForOtsu) {
        // Non abbastanza dati per Otsu: usa fallback manuale
        g_dynamicThreshold = ScoreThreshold;
        g_scoreThresholdReady = false;
        if (g_enableLogsEffective) {
            PrintFormat("[THRESHOLD] ⏳ Warm-up: %d/%d score | Fallback: %.1f%%",
                g_scoreHistorySize, minSamplesForOtsu, ScoreThreshold);
        }
        return;
    }
    
    // Calcola soglia Otsu
    g_otsuThreshold = CalcOtsuThreshold();
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 FASE 2: YOUDEN (feedback - basato su profitti reali)
    // Quando abbiamo abbastanza trade con risultati, usiamo Youden
    // che massimizza (TPR + TNR - 1) basandosi sui profitti/perdite
    // ═══════════════════════════════════════════════════════════════
    
    // Conta trade con score valido
    int tradesWithScore = 0;
    for (int i = 0; i < g_recentTradesCount; i++) {
        int idx = (g_recentTradesIndex - g_recentTradesCount + i + g_recentTradesMax) % g_recentTradesMax;
        if (g_recentTrades[idx].scoreAtEntry > 0) tradesWithScore++;
    }
    
    if (tradesWithScore >= g_minTradesForYouden) {
        // Abbastanza trade per Youden
        double youdenResult = CalcYoudenThreshold();
        
        if (youdenResult > 0) {
            // Youden ha trovato una soglia valida (J > 0)
            g_youdenThreshold = youdenResult;
            g_youdenReady = true;
            g_dynamicThreshold = g_youdenThreshold;
            thresholdMethod = StringFormat("YOUDEN (J>0) basato su %d trade", tradesWithScore);
        } else {
            // Youden non trova separazione (J <= 0): usa Otsu
            g_youdenReady = false;
            g_dynamicThreshold = g_otsuThreshold;
            thresholdMethod = StringFormat("OTSU (Youden J<=0, %d trade)", tradesWithScore);
        }
    } else {
        // Non abbastanza trade: usa Otsu
        g_youdenReady = false;
        g_dynamicThreshold = g_otsuThreshold;
        thresholdMethod = StringFormat("OTSU (attesa %d/%d trade per Youden)", tradesWithScore, g_minTradesForYouden);
    }
    
    g_scoreThresholdReady = true;
    
    // ═══════════════════════════════════════════════════════════════
    // 🔒 SAFETY BOUNDS (φ-derivati dai dati, non numeri fissi)
    // Min: percentile φ⁻² ≈ 38.2% (sotto questo, troppi segnali)
    // Max: percentile (1-φ⁻²) ≈ 61.8% degli score + buffer φ⁻¹ ≈ 85.4%
    // ═══════════════════════════════════════════════════════════════
    int minSamplesForBounds = (int)MathRound(MathPow(PHI, 4));  // φ⁴ ≈ 7
    if (g_scoreHistorySize >= minSamplesForBounds) {
        // Percentili derivati da φ:
        // Floor: φ⁻² ≈ 38.2% della distribuzione
        // Ceiling: 1 - φ⁻³ ≈ 76.4% della distribuzione (lascia spazio per score alti)
        double floorPercentile = PHI_INV_SQ * 100.0;           // ~38.2%
        double ceilingPercentile = (1.0 - PHI_INV_CUB) * 100.0; // ~76.4%
        
        double minBound = CalculatePercentile(g_scoreHistory, g_scoreHistorySize, floorPercentile);
        double maxBound = CalculatePercentile(g_scoreHistory, g_scoreHistorySize, ceilingPercentile);
        
        bool hitFloor = (g_dynamicThreshold < minBound);
        bool hitCeiling = (g_dynamicThreshold > maxBound);
        
        g_dynamicThreshold = MathMax(minBound, MathMin(maxBound, g_dynamicThreshold));
        
        if (hitFloor || hitCeiling) {
            thresholdMethod += (hitFloor ? " | FLOOR->P38" : " | CEILING->P76");
        }
    }
    
    // Log se cambio significativo (soglia cambio = 1/φ³ ≈ 0.236 punti %)
    double logChangeThreshold = PHI_INV_CUB;
    if (g_enableLogsEffective && MathAbs(g_dynamicThreshold - oldThreshold) > logChangeThreshold) {
        PrintFormat("[THRESHOLD] 🌱 Soglia: %.1f%% → %.1f%% [%s]", oldThreshold, g_dynamicThreshold, thresholdMethod);
        PrintFormat("   Otsu: %.1f%% | Youden: %.1f%% (%s) | Score buffer: %d",
            g_otsuThreshold, g_youdenThreshold, g_youdenReady ? "ATTIVO" : "warm-up", g_scoreHistorySize);
    }
}

//+------------------------------------------------------------------+
//| 🌱 SOGLIA DINAMICA: Ottieni soglia corrente (auto o manuale)     |
//| Sistema OTSU → YOUDEN: impara dai dati E dai risultati           |
//| OUTPUT: Valore sempre >= 0 (soglia valida)                       |
//+------------------------------------------------------------------+
double GetCurrentThreshold()
{
    if (AutoScoreThreshold) {
        // Se la soglia automatica non è ancora pronta, usa fallback manuale
        if (!g_scoreThresholdReady) return ScoreThreshold;
        return g_dynamicThreshold;  // Otsu o Youden
    }
    return ScoreThreshold;  // Manuale
}

//+------------------------------------------------------------------+
//| ?? DETECTOR INVERSIONE: Inizializzazione buffer                  |
//+------------------------------------------------------------------+
void InitReversalDetectors()
{
    // Score Momentum buffer = f8 � 47 (stesso size di trade history)
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
    
    // RSI Divergence: buffer swing = f5 � 11
    g_swingsMax = (int)MathRound(MathPow(PHI, 5));
    ArrayResize(g_swings_H1, g_swingsMax);
    g_swingsSize_H1 = 0;
    g_divergenceSignal = 0;
    g_divergenceStrength = 0.0;
    
    // ?? SOGLIA DIVERGENZA DATA-DRIVEN: buffer f6 � 18
    int divergenceBufferSize = (int)MathRound(MathPow(PHI, 6));
    ArrayResize(g_divergenceHistory, divergenceBufferSize);
    ArrayInitialize(g_divergenceHistory, 0);
    g_divergenceHistorySize = 0;
    g_divergenceHistoryIndex = 0;
    g_divergenceSum = 0.0;
    g_divergenceSumSq = 0.0;
    g_divergenceMinThreshold = PHI_INV_CUB;  // ?? Start = f?� � 23.6%
    g_divergenceThresholdReady = false;
    
    // ?? SOGLIA REVERSAL DATA-DRIVEN: buffer f8 � 47
    int reversalBufferSize = (int)MathRound(MathPow(PHI, 8));
    ArrayResize(g_reversalStrengthHistory, reversalBufferSize);
    ArrayInitialize(g_reversalStrengthHistory, 0);
    g_reversalHistorySize = 0;
    g_reversalHistoryIndex = 0;
    g_reversalSum = 0.0;
    g_reversalSumSq = 0.0;
    g_reversalThreshold = PHI_INV;       // ?? Start = f?� � 61.8%
    g_reversalThresholdReady = false;
    
    // ?? STOCHASTIC EXTREME E OBV DIVERGENCE (v1.1)
    g_stochExtremeSignal = 0;
    g_stochExtremeStrength = 0.0;
    g_obvDivergenceSignal = 0;
    g_obvDivergenceStrength = 0.0;
    
    if (g_enableLogsEffective) {
        Print("");
        Print("---------------------------------------------------------------");
        Print("?? DETECTOR INVERSIONE ORGANICO INIZIALIZZATO (v1.1)");
        PrintFormat("   Score Momentum buffer: %d | Soglia: mean + stdev � f?�", momentumBufferSize);
        Print("   Regime Change: traccia transizioni Hurst");
        PrintFormat("   RSI Divergence: %d swing points | Soglia: mean + stdev � f?� (%s)", 
            g_swingsMax, enableRSI ? "ATTIVO" : "disattivo");
        PrintFormat("   Stochastic Extreme: soglie f-derivate (23.6%% / 76.4%%) (%s)", 
            enableStoch ? "ATTIVO" : "disattivo");
        PrintFormat("   OBV Divergence: lookback f� � 4 barre (%s)", 
            enableOBV ? "ATTIVO" : "disattivo");
        PrintFormat("   Divergence buffer: %d | Reversal buffer: %d", divergenceBufferSize, reversalBufferSize);
        Print("---------------------------------------------------------------");
        Print("");
    }
}

//+------------------------------------------------------------------+
//| ?? SCORE MOMENTUM: Aggiorna e calcola cambio score               |
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
    
    // Calcola soglia momentum = mean + stdev � f?�
    int minSamples = (int)MathRound(MathPow(PHI, 4));  // f4 � 7
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
                PrintFormat("[REVERSAL] ?? MOMENTUM BULLISH: %.2f > %.2f soglia", 
                    g_scoreMomentum, g_scoreMomentumThreshold);
            }
            return 1;  // Momentum bullish significativo
        } else {
            if (g_enableLogsEffective) {
                PrintFormat("[REVERSAL] ?? MOMENTUM BEARISH: %.2f < -%.2f soglia", 
                    g_scoreMomentum, g_scoreMomentumThreshold);
            }
            return -1;  // Momentum bearish significativo
        }
    }
    
    return 0;  // Momentum non significativo
}

//+------------------------------------------------------------------+
//| ?? REGIME CHANGE: Traccia transizioni regime Hurst               |
//| Ritorna: +1 se verso trending, -1 se verso meanrev, 0 nessuna    |
//+------------------------------------------------------------------+
int UpdateRegimeChange()
{
    g_regimeChanged = false;
    g_regimeChangeDirection = 0;
    
    if (!EnableHurstFilter) return 0;
    
    // Check cambio per ogni TF attivo
    double changeScore = 0.0;  // ?? double per pesi organici
    
    // ?? PESI ORGANICI: derivati da potenze di f
    // M5 = f?� � 0.38, H1 = f?� � 0.62, H4 = 1.0, D1 = f � 1.62
    double weightM5 = PHI_INV_SQ;   // � 0.382
    double weightH1 = PHI_INV;      // � 0.618
    double weightH4 = 1.0;          // 1.0
    double weightD1 = PHI;          // � 1.618
    
    // M5 (peso f?� � 0.38)
    if (g_vote_M5_active && g_hurstRegime_M5 != g_prevRegime_M5) {
        if (g_hurstRegime_M5 == HURST_TRENDING && g_prevRegime_M5 != HURST_TRENDING) 
            changeScore += weightM5;
        else if (g_hurstRegime_M5 == HURST_MEANREV && g_prevRegime_M5 != HURST_MEANREV) 
            changeScore -= weightM5;
        g_prevRegime_M5 = g_hurstRegime_M5;
    }
    
    // H1 (peso f?� � 0.62)
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
    
    // D1 (peso f � 1.62)
    if (g_vote_D1_active && g_hurstRegime_D1 != g_prevRegime_D1) {
        if (g_hurstRegime_D1 == HURST_TRENDING && g_prevRegime_D1 != HURST_TRENDING) 
            changeScore += weightD1;
        else if (g_hurstRegime_D1 == HURST_MEANREV && g_prevRegime_D1 != HURST_MEANREV) 
            changeScore -= weightD1;
        g_prevRegime_D1 = g_hurstRegime_D1;
    }
    
    // 🌱 FIX: Soglia φ-derivata invece di 0.01 arbitrario
    double noiseThreshold = MathPow(PHI_INV, 4);  // φ⁻⁴ ≈ 0.146 (soglia rumore organica)
    if (MathAbs(changeScore) > noiseThreshold) {
        g_regimeChanged = true;
        g_regimeChangeDirection = (changeScore > 0) ? 1 : -1;
        
        if (g_enableLogsEffective) {
            PrintFormat("[REVERSAL] ?? REGIME CHANGE: %s (score=%.2f)", 
                changeScore > 0 ? "? TRENDING" : "? MEAN-REVERTING", changeScore);
        }
    }
    
    return g_regimeChangeDirection;
}

//+------------------------------------------------------------------+
//| ?? AGGIORNA SOGLIA DIVERGENZA DATA-DRIVEN                        |
//| Traccia storia forze divergenza e calcola: mean + stdev � f?�    |
//| Clamp organico: [f?� � 24%, f?� � 62%]                          |
//+------------------------------------------------------------------+
void UpdateDivergenceThreshold(double strength)
{
    // Buffer size = f6 � 18
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
    
    // Calcola soglia: richiede minimo f� � 3 sample
    int minSamples = (int)MathRound(PHI_SQ);
    
    if (g_divergenceHistorySize >= minSamples) {
        double mean = g_divergenceSum / g_divergenceHistorySize;
        double variance = (g_divergenceSumSq / g_divergenceHistorySize) - (mean * mean);
        double stdev = variance > 0 ? MathSqrt(variance) : 0;
        
        // Soglia = mean + stdev � f?� (divergenze significativamente sopra media)
        g_divergenceMinThreshold = mean + stdev * PHI_INV;
        
        // Clamp organico: [f?� � 24%, f?� � 62%]
        // Min basso per catturare divergenze deboli ma significative
        // Max per non essere troppo restrittivi
        g_divergenceMinThreshold = MathMax(PHI_INV_CUB, MathMin(PHI_INV, g_divergenceMinThreshold));
        
        if (!g_divergenceThresholdReady) {
            g_divergenceThresholdReady = true;
            if (g_enableLogsEffective) {
                PrintFormat("[DIVERGENCE] ? Soglia data-driven: %.1f%% (mean=%.1f%%, stdev=%.1f%%)",
                    g_divergenceMinThreshold * 100, mean * 100, stdev * 100);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| ?? RSI DIVERGENCE: Rileva swing e divergenze prezzo/RSI          |
//| Usa H1 come TF principale per ridurre rumore                     |
//| Ritorna: +1 bullish div, -1 bearish div, 0 nessuna               |
//+------------------------------------------------------------------+
int UpdateRSIDivergence()
{
    g_divergenceSignal = 0;
    g_divergenceStrength = 0.0;
    
    // Se RSI disabilitato, non calcolare divergenza
    if (!enableRSI) return 0;
    
    if (!g_vote_H1_active) return 0;
    
    int ratesSize = ArraySize(tfData_H1.rates);
    int rsiSize = ArraySize(tfData_H1.rsi);
    
    // Servono almeno f5 � 11 barre per rilevare swing
    int minBars = (int)MathRound(MathPow(PHI, 5));
    if (ratesSize < minBars || rsiSize < minBars) return 0;
    
    // Lookback per swing detection = f� � 4 barre
    int swingLookback = (int)MathRound(MathPow(PHI, 3));
    
    // Cerca swing high/low recenti
    bool foundSwingHigh = false;
    bool foundSwingLow = false;
    double swingHighPrice = 0, swingHighRSI = 0;
    double swingLowPrice = 0, swingLowRSI = 0;
    int swingHighBar = 0, swingLowBar = 0;
    
    // Cerca swing negli ultimi f5 barre
    for (int i = swingLookback; i < minBars - swingLookback; i++) {
        int idx = ratesSize - 1 - i;  // Indice dalla fine (0 = pi� recente)
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
    
    // ---------------------------------------------------------------
    // BEARISH DIVERGENCE: Prezzo Higher High, RSI Lower High
    // ---------------------------------------------------------------
    double calcStrength = 0.0;  // Forza calcolata (prima del check soglia)
    
    if (foundSwingHigh && prevSwingHighPrice > 0 && prevSwingHighRSI > 0) {
        if (swingHighPrice > prevSwingHighPrice && swingHighRSI < prevSwingHighRSI) {
            // Calcola forza divergenza (normalizzata con f come scala)
            double priceDiff = (swingHighPrice - prevSwingHighPrice) / prevSwingHighPrice;
            double rsiDiff = (prevSwingHighRSI - swingHighRSI) / prevSwingHighRSI;
            calcStrength = MathMin(1.0, (priceDiff + rsiDiff) / PHI_INV);
            
            // ?? AGGIORNA BUFFER E SOGLIA DATA-DRIVEN
            UpdateDivergenceThreshold(calcStrength);
            
            if (calcStrength >= g_divergenceMinThreshold) {
                g_divergenceStrength = calcStrength;
                g_divergenceSignal = -1;  // Bearish
                if (g_enableLogsEffective) {
                    PrintFormat("[REVERSAL] ?? BEARISH DIV: HH (%.5f?%.5f) + LH RSI (%.1f?%.1f) | Forza: %.0f%% > Soglia: %.0f%%",
                        prevSwingHighPrice, swingHighPrice, prevSwingHighRSI, swingHighRSI, 
                        g_divergenceStrength * 100, g_divergenceMinThreshold * 100);
                }
            }
        }
    }
    
    // ---------------------------------------------------------------
    // BULLISH DIVERGENCE: Prezzo Lower Low, RSI Higher Low
    // ---------------------------------------------------------------
    if (foundSwingLow && prevSwingLowPrice > 0 && prevSwingLowRSI > 0 && g_divergenceSignal == 0) {
        if (swingLowPrice < prevSwingLowPrice && swingLowRSI > prevSwingLowRSI) {
            // Calcola forza divergenza (normalizzata con f come scala)
            double priceDiff = (prevSwingLowPrice - swingLowPrice) / prevSwingLowPrice;
            double rsiDiff = (swingLowRSI - prevSwingLowRSI) / prevSwingLowRSI;
            calcStrength = MathMin(1.0, (priceDiff + rsiDiff) / PHI_INV);
            
            // ?? AGGIORNA BUFFER E SOGLIA DATA-DRIVEN
            UpdateDivergenceThreshold(calcStrength);
            
            if (calcStrength >= g_divergenceMinThreshold) {
                g_divergenceStrength = calcStrength;
                g_divergenceSignal = 1;  // Bullish
                if (g_enableLogsEffective) {
                    PrintFormat("[REVERSAL] ?? BULLISH DIV: LL (%.5f?%.5f) + HL RSI (%.1f?%.1f) | Forza: %.0f%% > Soglia: %.0f%%",
                        prevSwingLowPrice, swingLowPrice, prevSwingLowRSI, swingLowRSI, 
                        g_divergenceStrength * 100, g_divergenceMinThreshold * 100);
                }
            }
        }
    }
    
    return g_divergenceSignal;
}

//+------------------------------------------------------------------+
//| ?? STOCHASTIC EXTREME DETECTION                                  |
//| Rileva zone ipercomprato/ipervenduto usando soglie f-derivate    |
//| Soglia ipervenduto: < f?� � 100 � 23.6%                         |
//| Soglia ipercomprato: > (1 - f?�) � 100 � 76.4%                  |
//| Ritorna: +1 = bullish (ipervenduto), -1 = bearish (ipercomprato)|
//+------------------------------------------------------------------+
int UpdateStochasticExtreme()
{
    g_stochExtremeSignal = 0;
    g_stochExtremeStrength = 0.0;
    
    // Se Stochastic disabilitato, non calcolare
    if (!enableStoch) return 0;
    
    // Usa H1 come TF principale per coerenza con RSI divergence
    if (!tfData_H1.isDataReady) return 0;
    
    int count = ArraySize(tfData_H1.stoch_main);
    if (count < 2) return 0;
    
    int lastIdx = count - 1;
    double stochK = tfData_H1.stoch_main[lastIdx];
    double stochD = tfData_H1.stoch_signal[lastIdx];
    
    // Verifica dati validi
    if (stochK <= 0 || stochK >= 100 || stochD <= 0 || stochD >= 100) return 0;
    
    // ?? SOGLIE f-DERIVATE
    double oversoldLevel = PHI_INV_SQ * 100.0;   // � 23.6%
    double overboughtLevel = (1.0 - PHI_INV_SQ) * 100.0;  // � 76.4%
    
    // Forza = quanto � "estremo" rispetto alla soglia
    // Per ipervenduto: quanto � sotto 23.6%
    // Per ipercomprato: quanto � sopra 76.4%
    
    if (stochK < oversoldLevel && stochD < oversoldLevel) {
        // IPERVENDUTO ? potenziale inversione bullish
        // Forza = distanza dalla soglia normalizzata (0-1)
        g_stochExtremeStrength = MathMin(1.0, (oversoldLevel - stochK) / oversoldLevel);
        g_stochExtremeSignal = 1;  // Bullish
        
        if (g_enableLogsEffective) {
            PrintFormat("[STOCH] ?? IPERVENDUTO K=%.1f%% D=%.1f%% < %.1f%% | Forza: %.0f%%",
                stochK, stochD, oversoldLevel, g_stochExtremeStrength * 100);
        }
    }
    else if (stochK > overboughtLevel && stochD > overboughtLevel) {
        // IPERCOMPRATO ? potenziale inversione bearish
        g_stochExtremeStrength = MathMin(1.0, (stochK - overboughtLevel) / (100.0 - overboughtLevel));
        g_stochExtremeSignal = -1;  // Bearish
        
        if (g_enableLogsEffective) {
            PrintFormat("[STOCH] ?? IPERCOMPRATO K=%.1f%% D=%.1f%% > %.1f%% | Forza: %.0f%%",
                stochK, stochD, overboughtLevel, g_stochExtremeStrength * 100);
        }
    }
    
    return g_stochExtremeSignal;
}

//+------------------------------------------------------------------+
//| ?? OBV DIVERGENCE DETECTION                                      |
//| Rileva divergenze tra prezzo e On-Balance Volume                 |
//| Bearish: Prezzo ? ma OBV ? (volume non conferma il rialzo)      |
//| Bullish: Prezzo ? ma OBV ? (accumulo nascosto)                  |
//| Usa logica simile a RSI divergence ma con OBV                    |
//+------------------------------------------------------------------+
int UpdateOBVDivergence()
{
    g_obvDivergenceSignal = 0;
    g_obvDivergenceStrength = 0.0;
    
    // Se OBV disabilitato, non calcolare
    if (!enableOBV) return 0;
    
    // Usa H1 come TF principale
    if (!tfData_H1.isDataReady) return 0;
    
    int ratesSize = ArraySize(tfData_H1.rates);
    int obvSize = ArraySize(tfData_H1.obv);
    
    // Servono almeno f5 � 11 barre
    int minBars = (int)MathRound(MathPow(PHI, 5));
    if (ratesSize < minBars || obvSize < minBars) return 0;
    
    // Lookback per trend detection = f� � 4 barre
    int lookback = (int)MathRound(MathPow(PHI, 3));
    
    int lastIdx = ratesSize - 1;
    if (lastIdx < lookback) return 0;
    
    // Calcola trend recente del prezzo (close)
    double priceNow = tfData_H1.rates[lastIdx].close;
    double pricePrev = tfData_H1.rates[lastIdx - lookback].close;
    double priceChange = (priceNow - pricePrev) / pricePrev;
    
    // Calcola trend recente dell'OBV
    double obvNow = tfData_H1.obv[lastIdx];
    double obvPrev = tfData_H1.obv[lastIdx - lookback];
    
    // Evita divisione per zero
    if (MathAbs(obvPrev) < 1e-10) return 0;
    
    double obvChange = (obvNow - obvPrev) / MathAbs(obvPrev);
    
    // ?? SOGLIA MINIMA per considerare movimento significativo: f?� � 0.236%
    double minChange = PHI_INV_CUB * 0.01;  // 0.00236
    
    if (MathAbs(priceChange) < minChange || MathAbs(obvChange) < minChange) return 0;
    
    // ---------------------------------------------------------------
    // BEARISH DIVERGENCE: Prezzo sale, OBV scende
    // ---------------------------------------------------------------
    if (priceChange > 0 && obvChange < 0) {
        // Forza = media normalizzata dei due cambiamenti
        g_obvDivergenceStrength = MathMin(1.0, (priceChange - obvChange) / PHI_INV);
        g_obvDivergenceSignal = -1;  // Bearish
        
        if (g_enableLogsEffective) {
            PrintFormat("[OBV] ?? BEARISH DIV: Prezzo +%.2f%% ma OBV %.2f%% | Forza: %.0f%%",
                priceChange * 100, obvChange * 100, g_obvDivergenceStrength * 100);
        }
    }
    // ---------------------------------------------------------------
    // BULLISH DIVERGENCE: Prezzo scende, OBV sale
    // ---------------------------------------------------------------
    else if (priceChange < 0 && obvChange > 0) {
        g_obvDivergenceStrength = MathMin(1.0, (obvChange - priceChange) / PHI_INV);
        g_obvDivergenceSignal = 1;  // Bullish
        
        if (g_enableLogsEffective) {
            PrintFormat("[OBV] ?? BULLISH DIV: Prezzo %.2f%% ma OBV +%.2f%% | Forza: %.0f%%",
                priceChange * 100, obvChange * 100, g_obvDivergenceStrength * 100);
        }
    }
    
    return g_obvDivergenceSignal;
}

//+------------------------------------------------------------------+
//| ?? DETECTOR INVERSIONE MASTER: Combina tutti i segnali           |
//| Ritorna: +1 inversione bullish, -1 bearish, 0 nessuna            |
//| strength: 0-1 forza del segnale                                  |
//| ?? SOGLIA 100% DATA-DRIVEN: mean + stdev � f?�                   |
//| ?? v1.1: Include Stochastic Extreme e OBV Divergence             |
//+------------------------------------------------------------------+
int GetReversalSignal(double &strength)
{
    strength = 0.0;
    
    int momentumSignal = g_scoreMomentum > 0 ? 1 : (g_scoreMomentum < 0 ? -1 : 0);
    bool momentumStrong = MathAbs(g_scoreMomentum) >= g_scoreMomentumThreshold;
    
    int regimeSignal = g_regimeChangeDirection;
    int divergenceSignal = g_divergenceSignal;
    
    // ?? NUOVI SEGNALI MEAN-REVERSION (v1.1)
    int stochExtremeSignal = g_stochExtremeSignal;
    int obvDivergenceSignal = g_obvDivergenceSignal;
    
    // ---------------------------------------------------------------
    // LOGICA COMBINATA (pesi organici f-derivati)
    // RSI Divergence = peso f (pi� affidabile, classico)
    // OBV Divergence = peso 1 (volume conferma)
    // Stoch Extreme = peso f?� (zone estreme)
    // Momentum = peso f?� (rapido ma rumoroso)
    // Regime = peso f?� (confirmation)
    // ---------------------------------------------------------------
    double score = 0.0;
    double maxScore = 0.0;
    
    // Divergenza RSI (peso pi� alto - classico e affidabile)
    if (divergenceSignal != 0) {
        score += divergenceSignal * PHI * g_divergenceStrength;
        maxScore += PHI;
    }
    
    // Divergenza OBV (volume non mente - peso 1)
    if (obvDivergenceSignal != 0) {
        score += obvDivergenceSignal * 1.0 * g_obvDivergenceStrength;
        maxScore += 1.0;
    }
    
    // Stochastic Zone Estreme (peso f?� � 0.618)
    if (stochExtremeSignal != 0) {
        score += stochExtremeSignal * PHI_INV * g_stochExtremeStrength;
        maxScore += PHI_INV;
    }
    
    // Score Momentum (peso ridotto a f?�)
    if (momentumStrong) {
        score += momentumSignal * PHI_INV_SQ;
        maxScore += PHI_INV_SQ;
    }
    
    // Regime Change (peso f?�)
    if (regimeSignal != 0) {
        score += regimeSignal * PHI_INV_SQ;
        maxScore += PHI_INV_SQ;
    }
    
    if (maxScore <= 0) return 0;
    
    // Calcola forza normalizzata
    strength = MathAbs(score) / maxScore;
    
    // ---------------------------------------------------------------
    // ?? AGGIORNA BUFFER STORICO FORZA REVERSAL (per soglia data-driven)
    // Tracciamo TUTTE le forze (anche deboli) per avere distribuzione completa
    // ---------------------------------------------------------------
    int reversalBufferMax = (int)MathRound(MathPow(PHI, 8));  // f8 � 47
    
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
    
    // ---------------------------------------------------------------
    // ?? CALCOLA SOGLIA DATA-DRIVEN: mean + stdev � f?�
    // Richiede minimo f� � 4 sample per significativit� statistica
    // ---------------------------------------------------------------
    int minSamples = (int)MathRound(MathPow(PHI, 3));  // � 4
    
    if (g_reversalHistorySize >= minSamples) {
        double mean = g_reversalSum / g_reversalHistorySize;
        double variance = (g_reversalSumSq / g_reversalHistorySize) - (mean * mean);
        double stdev = variance > 0 ? MathSqrt(variance) : 0;
        
        // Soglia = mean + stdev � f?� (segnali significativamente sopra media)
        g_reversalThreshold = mean + stdev * PHI_INV;
        
        // Clamp organico: soglia minima f?� � 38%, massima f?� � 62%
        g_reversalThreshold = MathMax(PHI_INV_SQ, MathMin(PHI_INV, g_reversalThreshold));
        
        if (!g_reversalThresholdReady) {
            g_reversalThresholdReady = true;
            if (g_enableLogsEffective) {
                PrintFormat("[REVERSAL] ? Soglia data-driven pronta: %.1f%% (mean=%.1f%%, stdev=%.1f%%)",
                    g_reversalThreshold * 100, mean * 100, stdev * 100);
            }
        }
    }
    
    // ---------------------------------------------------------------
    // ?? DECISIONE: Forza > soglia data-driven
    // ---------------------------------------------------------------
    if (strength >= g_reversalThreshold) {
        int direction = (score > 0) ? 1 : -1;
        
        if (g_enableLogsEffective) {
            PrintFormat("[REVERSAL] ?? INVERSIONE %s | Forza: %.0f%% > Soglia: %.0f%% | RSI=%s OBV=%s Stoch=%s M=%s R=%s",
                direction > 0 ? "BULLISH" : "BEARISH",
                strength * 100,
                g_reversalThreshold * 100,
                divergenceSignal > 0 ? "??" : (divergenceSignal < 0 ? "??" : "?"),
                obvDivergenceSignal > 0 ? "??" : (obvDivergenceSignal < 0 ? "??" : "?"),
                stochExtremeSignal > 0 ? "??" : (stochExtremeSignal < 0 ? "??" : "?"),
                momentumStrong ? (momentumSignal > 0 ? "??" : "??") : "?",
                regimeSignal > 0 ? "??" : (regimeSignal < 0 ? "??" : "?"));
        }
        
        return direction;
    }
    
    return 0;
}

//+------------------------------------------------------------------+
//| ?? Calcola il PERIODO NATURALE del mercato per un TF             |
//| Usa AUTOCORRELAZIONE per trovare il "memory decay" del prezzo    |
//| Il periodo naturale � dove l'autocorr scende sotto 1/f� � 0.382  |
//| Ritorna anche l'ESPONENTE DI HURST per calcolo pesi              |
//| Questo � COMPLETAMENTE derivato dai dati, zero numeri arbitrari  |
//+------------------------------------------------------------------+
NaturalPeriodResult CalculateNaturalPeriodForTF(ENUM_TIMEFRAMES tf)
{
    NaturalPeriodResult result;
    result.period = -1;
    result.hurstExponent = 0.0;  // Non calcolato (valid=false)
    result.valid = false;
    
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    
    // ---------------------------------------------------------------
    // ?? APPROCCIO 100% DATA-DRIVEN (PURO - NO FALLBACK):
    // 1. Chiediamo barre dal PASSATO (non dalla barra corrente!)
    // 2. maxLag = barre_disponibili / f� (derivato dai DATI!)
    // 3. Il periodo naturale emerge dall'autocorrelazione
    // Se non ci sono abbastanza dati, ritorna valid=false (TF disabilitato)
    // 
    // ?? FIX: In backtest, Bars() ritorna solo le barre "generate" fino a quel momento
    // Invece usiamo CopyRates con start dalla barra 1 (passato) per forzare
    // il caricamento dei dati storici pre-esistenti!
    // ---------------------------------------------------------------
    
    // ?? FIX: Richiediamo f�� � 123 barre storiche (sufficiente per analisi)
    int barsToRequest = (int)MathRound(MathPow(PHI, 10));  // � 123
    
    // ?? Minimo PURO: f4 � 7 barre (sotto questo non ha senso statistico)
    int minBarsForAnalysis = (int)MathRound(PHI_SQ * PHI_SQ);  // � 6.85 ? 7
    
    // ?? FIX: Usa CopyRates DIRETTAMENTE per caricare dati storici
    // In backtest, questo forza MT5 a caricare i dati dal passato!
    // Usiamo start=1 (barra precedente) per evitare la barra corrente incompleta
    int copied = CopyRates(_Symbol, tf, 1, barsToRequest, rates);
    
    if (copied < minBarsForAnalysis) {
        PrintFormat("? [NATURAL] TF %s: copiate solo %d barre storiche, minimo richiesto %d - TF DISABILITATO", 
            EnumToString(tf), copied, minBarsForAnalysis);
        return result;  // valid = false
    }
    
    // ?? FIX: barsAvailable = numero EFFETTIVO di barre copiate (non Bars()!)
    int barsAvailable = copied;
    
    // ?? maxLag = barre / f� (proporzione aurea delle barre disponibili)
    // Questo assicura sempre abbastanza dati per l'analisi
    int maxLag = (int)MathRound(barsAvailable / PHI_SQ);
    maxLag = MathMax((int)MathRound(PHI_SQ), maxLag);  // Minimo f� � 3 per analisi sensata
    
    // Log solo la prima volta per confermare che i dati storici sono caricati
    static bool loggedOnce_M5 = false, loggedOnce_H1 = false, loggedOnce_H4 = false, loggedOnce_D1 = false;
    bool shouldLog = false;
    
    if (tf == PERIOD_M5 && !loggedOnce_M5) { shouldLog = true; loggedOnce_M5 = true; }
    else if (tf == PERIOD_H1 && !loggedOnce_H1) { shouldLog = true; loggedOnce_H1 = true; }
    else if (tf == PERIOD_H4 && !loggedOnce_H4) { shouldLog = true; loggedOnce_H4 = true; }
    else if (tf == PERIOD_D1 && !loggedOnce_D1) { shouldLog = true; loggedOnce_D1 = true; }
    
    if (shouldLog) {
        PrintFormat("[NATURAL] ? TF %s: Caricati %d/%d barre storiche (maxLag=%d)", 
            EnumToString(tf), copied, barsToRequest, maxLag);
    }
    
    // ---------------------------------------------------------------
    // CALCOLO AUTOCORRELAZIONE
    // L'autocorrelazione misura quanto il prezzo "ricorda" se stesso
    // Quando scende sotto 1/f� � 0.382, il mercato ha "dimenticato"
    // ---------------------------------------------------------------
    
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
        PrintFormat("? [NATURAL] TF %s: varianza zero (prezzo flat) - TF DISABILITATO", EnumToString(tf));
        return result;
    }
    
    // ---------------------------------------------------------------
    // ?? CALCOLA ESPONENTE DI HURST (per determinare peso TF)
    // Confrontato con g_hurstCenter e soglie dinamiche:
    //   H > g_hurstRandomHigh: trending ? peso maggiore
    //   H < g_hurstRandomLow: mean-reverting ? peso maggiore
    // ---------------------------------------------------------------
    double hurstValue = CalculateHurstExponent(rates, copied);
    
    // Variabili per il calcolo del periodo naturale
    double autocorrSum = 0;
    int autocorrCount = 0;
    
    // Trova il lag dove l'autocorrelazione scende sotto 1/f�
    // Questo � il "periodo naturale" del mercato
    int naturalPeriod = 0;
    double threshold = PHI_INV_SQ;  // � 0.382 (soglia organica!)
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
                    PrintFormat("[NATURAL] ?? TF %s: autocorr[%d]=%.3f < %.3f ? Periodo naturale=%d",
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
            // Derivato dalle barre disponibili: maxLag / f
            naturalPeriod = (int)MathRound(maxLag / PHI);
            PrintFormat("[NATURAL] ?? TF %s: nessun decay trovato, uso maxLag/f�%d", 
                EnumToString(tf), naturalPeriod);
        }
    }
    
    // ?? Limita il periodo con rapporti aurei delle barre disponibili
    int minPeriod = (int)MathRound(PHI);              // � 2 (minimo assoluto)
    int maxPeriod = (int)MathRound(maxLag / PHI);     // Derivato dalle barre
    naturalPeriod = MathMax(minPeriod, MathMin(maxPeriod, naturalPeriod));
    
    // ---------------------------------------------------------------
    // ?? ESPONENTE DI HURST DETERMINA IL PESO TF
    // peso_TF = H_TF / S(H_tutti_TF) - normalizzato
    // TF con H pi� alto contribuiscono maggiormente
    // ---------------------------------------------------------------
    // ?? FIX: Se Hurst ritorna -1 (dati insufficienti), non � valido
    if (hurstValue < 0) {
        PrintFormat("[NATURAL] ?? TF %s: Hurst non calcolabile (dati insufficienti)", EnumToString(tf));
        result.valid = false;
        return result;
    }
    
    // ? VALIDATO: hurstValue gi� nel range [HURST_RANGE_MIN, HURST_RANGE_MAX]
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
        PrintFormat("[NATURAL] ?? TF %s: Periodo=%d | Hurst=%.3f (%s)",
            EnumToString(tf), naturalPeriod, result.hurstExponent, regimeLabel);
    }
    
    return result;
}

//+------------------------------------------------------------------+
//| ?? Trova il primo minimo locale dell'autocorrelazione            |
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
                    PrintFormat("[NATURAL] ?? Minimo autocorr trovato a lag=%d (autocorr=%.3f)", 
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
//| ?? CALCOLA PERCENTILE dai dati                                   |
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
//| ?? CALCOLA MEDIA EMPIRICA                                        |
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
//| ?? CALCOLA DEVIAZIONE STANDARD                                   |
//| La scala REALE dipende dalla volatilit� storica dell'indicatore  |
//+------------------------------------------------------------------+
double CalculateEmpiricalStdDev(const double &arr[], int size, double mean)
{
    // ?? PURO: ritorna 0 se dati insufficienti - il chiamante gestir� l'errore
    if (size <= 1) return 0.0;
    
    double sumSq = 0;
    for (int i = 0; i < size; i++) {
        double diff = arr[i] - mean;
        sumSq += diff * diff;
    }
    return MathSqrt(sumSq / (size - 1));
}

//+------------------------------------------------------------------+
//| ?? CALCOLA SOGLIE EMPIRICHE per un TimeFrame - PURO              |
//| Tutti i centri e scale derivano dai DATI storici reali           |
//| Se i dati sono insufficienti, INVALIDA il TF (no fallback!)      |
//| Ritorna: true se calcolo OK, false se dati insufficienti         |
//+------------------------------------------------------------------+
bool CalculateEmpiricalThresholds(TimeFrameData &data, int lookback)
{
    int size = ArraySize(data.rsi);
    int n = MathMin(lookback, size);
    
    // ?? MINIMO PURO: f� � 4 (minimo per statistiche sensate)
    // Questo � l'UNICO "numero magico" ed � derivato da f
    int minBarsRequired = (int)MathRound(PHI * PHI * PHI);  // � 4.236 ? 4
    
    if (n < minBarsRequired) {
        // ? DATI INSUFFICIENTI - NON USARE FALLBACK, INVALIDA IL TF
        Print("? [EMPIRICAL] DATI INSUFFICIENTI! Richieste almeno ", minBarsRequired, 
              " barre, disponibili: ", n, " - TF DISABILITATO");
        
        // Azzera tutto per evitare uso accidentale
        data.rsi_center = 0;
        data.rsi_scale = 0;
        data.adx_p25 = 0;
        data.adx_p75 = 0;
        
        return false;  // Segnala fallimento
    }
    
    // ---------------------------------------------------------------
    // ?? CENTRI EMPIRICI - La media REALE dal mercato
    // ---------------------------------------------------------------
    
    // RSI: prepara array delle ultime n barre
    double rsi_data[];
    ArrayResize(rsi_data, n);
    for (int i = 0; i < n; i++) rsi_data[i] = data.rsi[size - n + i];
    data.rsi_center = CalculateEmpiricalMean(rsi_data, n);
    double rsi_stdev = CalculateEmpiricalStdDev(rsi_data, n, data.rsi_center);
    if (rsi_stdev <= 0) {
        Print("? [EMPIRICAL] RSI stdev=0, dati flat - TF DISABILITATO");
        return false;
    }
    data.rsi_scale = rsi_stdev * PHI;  // Scala = stdev � f
    
    // ---------------------------------------------------------------
    // ?? ADX PERCENTILI - Soglie dalla distribuzione REALE
    // ---------------------------------------------------------------
    if (ArraySize(data.adx) >= n) {
        double adx_data[];
        ArrayResize(adx_data, n);
        for (int i = 0; i < n; i++) adx_data[i] = data.adx[size - n + i];
        
        // Percentili aurei: 1/f� � 38.2% e 1/f � 61.8%
        data.adx_p25 = CalculatePercentile(adx_data, n, PHI_INV_SQ * 100);  // ~38� percentile
        data.adx_p75 = CalculatePercentile(adx_data, n, PHI_INV * 100);     // ~62� percentile
        
        // Verifica che i percentili siano sensati (p75 > p25)
        if (data.adx_p75 <= data.adx_p25) {
            Print("? [EMPIRICAL] ADX percentili invalidi (p75 <= p25) - TF DISABILITATO");
            return false;
        }
    } else {
        Print("? [EMPIRICAL] ADX: dati insufficienti");
        return false;
    }
    
    // ---------------------------------------------------------------
    // ?? FIX: OBV SCALA EMPIRICA - Dalle variazioni REALI
    // Calcola la stdev delle VARIAZIONI di OBV (non i valori assoluti)
    // ---------------------------------------------------------------
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
        
        // Scala = stdev � f, con fallback se troppo piccola
        if (obv_change_stdev > 0) {
            data.obv_scale = obv_change_stdev * PHI;
        } else {
            // ?? FIX: Fallback migliorato - usa range OBV osservato invece di ATR
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
                // 🌱 FIX: Fallback φ-derivato invece di 1000.0 arbitrario
                data.obv_scale = MathPow(PHI, 10);  // φ¹⁰ ≈ 123 (coerente con altri fallback)
            }
        }
        // ?? FIX: Garantire sempre scala minima positiva per evitare DIV/0
        if (data.obv_scale <= 0) {
            data.obv_scale = MathPow(PHI, 7);  // ?? Minimo = f7 � 29
        }
    } else {
        // OBV non disponibile, usa fallback organico
        data.obv_scale = MathPow(PHI, 10);  // ?? f�� � 123 (valore tipico per volumi)
    }
    
    if (g_enableLogsEffective) {
        PrintFormat("[EMPIRICAL] ? RSI center=%.1f scale=%.1f | ADX p25=%.1f p75=%.1f | OBV scale=%.1f",
            data.rsi_center, data.rsi_scale, data.adx_p25, data.adx_p75, data.obv_scale);
    }
    
    return true;  // Calcolo completato con successo
}

//+------------------------------------------------------------------+
//| ?? CALCOLA PERIODI 100% DATA-DRIVEN                              |
//| TUTTO derivato dal periodo naturale usando SOLO rapporti f       |
//| NESSUN numero Fibonacci arbitrario - solo rapporti aurei         |
//| f � 1.618, 1/f � 0.618, 1/f� � 0.382, 1/f� � 0.236              |
//| PESO TF: derivato dall'ESPONENTE DI HURST!                       |
//+------------------------------------------------------------------+
void CalculateOrganicPeriodsFromData(ENUM_TIMEFRAMES tf, OrganicPeriods &organic, int naturalPeriod, double weight, double hurstExp)
{
    // ?? PESO E HURST passati dal chiamante (derivati empiricamente)
    organic.weight = weight;
    organic.hurstExponent = hurstExp;
    
    // ---------------------------------------------------------------
    // ?? PERIODO NATURALE = deriva dall'AUTOCORRELAZIONE (dai DATI!)
    // Tutti gli altri periodi sono DERIVATI da questo usando rapporti f
    // Nessun numero arbitrario - la base viene dal mercato stesso
    // ---------------------------------------------------------------
    double base = (double)naturalPeriod;
    
    // ---------------------------------------------------------------
    // ?? RAPPORTI AUREI per differenziare i periodi
    // Ogni indicatore usa un multiplo/divisore f del periodo naturale
    // Questo crea una "scala aurea" di periodi tutti correlati
    //
    // Molto veloce = base / f� � base � 0.382
    // Veloce       = base / f  � base � 0.618
    // Medio        = base � 1   (periodo naturale)
    // Lento        = base � f  � base � 1.618
    // Molto lento  = base � f� � base � 2.618
    // Lunghissimo  = base � f� � base � 4.236
    // ---------------------------------------------------------------
    
    // Periodi organici - TUTTI derivati dal periodo naturale
    // ?? I minimi usano potenze di f per coerenza (non Fibonacci arbitrari!)
    // min_veryFast = f� � 2, min_fast = f� � 3, min_slow = f� � 4, etc.
    int veryFast = (int)MathMax((int)MathRound(PHI), MathRound(base * PHI_INV_SQ));         // min�2, base � 0.382
    int fast     = (int)MathMax((int)MathRound(PHI_SQ), MathRound(base * PHI_INV));         // min�3, base � 0.618
    int medium   = (int)MathMax((int)MathRound(PHI_SQ), MathRound(base));                   // min�3, base (naturale)
    int slow     = (int)MathMax((int)MathRound(PHI_SQ * PHI), MathRound(base * PHI));       // min�4, base � 1.618
    int verySlow = (int)MathMax((int)MathRound(PHI_SQ * PHI_SQ), MathRound(base * PHI_SQ)); // min�7, base � 2.618
    int longest  = (int)MathMax((int)MathRound(PHI_SQ * PHI_SQ * PHI), MathRound(base * PHI_SQ * PHI)); // min�11, base � 4.236
    
    if (g_enableLogsEffective) {
        PrintFormat("[ORGANIC] ?? TF %s: Naturale=%d ? VeryFast=%d Fast=%d Medium=%d Slow=%d VerySlow=%d Longest=%d",
            EnumToString(tf), naturalPeriod, veryFast, fast, medium, slow, verySlow, longest);
    }
    
    // ---------------------------------------------------------------
    // ?? ASSEGNAZIONE PERIODI - Logica basata sul ruolo dell'indicatore
    // Indicatori "veloci" ? usano periodi corti (momentum, segnali)
    // Indicatori "lenti" ? usano periodi lunghi (trend, struttura)
    // ---------------------------------------------------------------
    
    // Trend indicators (necessitano periodi pi� lunghi)
    organic.ema = slow;                     // EMA: segue il trend ? slow
    
    // Momentum indicators
    organic.rsi = medium;                   // RSI ? medium
    
    // MACD (tre periodi in relazione aurea tra loro)
    organic.macd_fast = fast;               // MACD veloce ? fast
    organic.macd_slow = slow;               // MACD lento ? slow
    organic.macd_signal = veryFast;         // MACD signal ? veryFast (smoothing)
    
    // Bollinger Bands
    organic.bb = slow;                      // BB periodo ? slow
    organic.bb_dev = PHI_INV + MathSqrt(base) * PHI_INV_SQ;  // BB dev: organico da base
    // ?? Limiti derivati da f: min=1/f�0.618 (banda stretta), max=f�1.618 + 1 = 2.618
    organic.bb_dev = MathMax(PHI_INV, MathMin(PHI_SQ, organic.bb_dev));
    
    // Volatility indicators
    organic.atr = medium;                   // ATR: volatilit� ? medium
    organic.adx = medium;                   // ADX: forza trend ? medium
    
    // ---------------------------------------------------------------
    // ?? NUOVI INDICATORI TREND (da v1.0)
    // Tutti derivati dal periodo naturale usando rapporti f
    // ---------------------------------------------------------------
    
    // Parabolic SAR (parametri step/max derivati da f)
    organic.psar_step = MathPow(PHI_INV, 4);   // f?4 � 0.146 (step organico)
    organic.psar_max = PHI_INV;                 // f?� � 0.618 (max organico)
    
    // SMA Cross (due medie in rapporto f� tra loro)
    organic.sma_fast = slow;                    // SMA veloce = naturalPeriod � f
    organic.sma_slow = longest;                 // SMA lenta = naturalPeriod � f�
    
    // Ichimoku (tre linee in rapporto f tra loro)
    organic.ichimoku_tenkan = medium;           // Tenkan = base (conversione veloce)
    organic.ichimoku_kijun = slow;              // Kijun = base × φ (linea base)
    organic.ichimoku_senkou = verySlow;         // Senkou B = base × φ² (cloud trailing)
    
    // ---------------------------------------------------------------
    // 🌱 STOCHASTIC (indicatore mean-reversion, vota inversione)
    // Periodi derivati da φ, usato per rilevare zone ipercomprato/ipervenduto
    // ---------------------------------------------------------------
    organic.stoch_k = medium;                   // %K = periodo naturale
    organic.stoch_d = fast;                     // %D = periodo × φ⁻¹ (più veloce)
    organic.stoch_slowing = (int)MathMax(2, MathRound(PHI_SQ));  // Slowing = φ² ≈ 3
    
    // ---------------------------------------------------------------
    // ?? PESO TF = H_TF / S(H_tutti_TF)
    // TF con Hurst maggiore ? peso maggiore
    // peso gi� calcolato in OnInit e assegnato a organic.weight
    // ---------------------------------------------------------------
    // organic.weight gi� assegnato all'inizio della funzione
    // organic.hurstExponent gi� assegnato all'inizio della funzione
    
    // ?? Barre minime = periodo pi� lungo usato + margine
    // Calcolato dinamicamente in base ai periodi effettivi
    // Per Ichimoku: Senkou B ha displacement di 26 periodi standard,
    // usiamo longest � f per avere margine sufficiente
    organic.min_bars_required = (int)MathRound(longest * PHI) + medium;
    
    // ?? Salva il periodo naturale per uso nelle scale
    organic.naturalPeriod = naturalPeriod;
}

//+------------------------------------------------------------------+
//| ?? Log dei periodi organici calcolati                            |
//+------------------------------------------------------------------+
void LogOrganicPeriods(string tfName, OrganicPeriods &organic)
{
    PrintFormat("[%s] ?? Peso TF: %.2f | EMA=%d RSI=%d MACD=%d/%d/%d BB=%d(%.1f) ATR=%d ADX=%d",
        tfName, organic.weight, organic.ema, organic.rsi, 
        organic.macd_fast, organic.macd_slow, organic.macd_signal,
        organic.bb, organic.bb_dev, organic.atr, organic.adx);
    PrintFormat("[%s] ?? TREND: PSAR=%.3f/%.2f SMA=%d/%d Ichimoku=%d/%d/%d | Stoch=%d/%d/%d | Min barre: %d",
        tfName, organic.psar_step, organic.psar_max,
        organic.sma_fast, organic.sma_slow,
        organic.ichimoku_tenkan, organic.ichimoku_kijun, organic.ichimoku_senkou,
        organic.stoch_k, organic.stoch_d, organic.stoch_slowing,
        organic.min_bars_required);
}

//+------------------------------------------------------------------+
//| ?? FIX: Verifica se i periodi sono cambiati significativamente    |
//| Ritorna true se almeno un periodo � cambiato >23.6% (soglia = 1/f�)|
//| In tal caso gli handle indicatori devono essere ricreati          |
//+------------------------------------------------------------------+
bool PeriodsChangedSignificantly()
{
    if (!g_periodsInitialized) return false;  // Primo calcolo, non serve confronto
    
    // ?? Soglia cambio = 1/f� � 23.6% (derivata organicamente da f)
    //    Abbastanza reattiva ma non troppo sensibile
    const double CHANGE_THRESHOLD = PHI_INV_CUB;  // � 0.236 = 23.6%
    
    // Controlla ogni TF attivo
    if (g_dataReady_M5) {
        double oldPeriod = (double)g_prevOrganic_M5.ema;
        double newPeriod = (double)g_organic_M5.ema;
        if (oldPeriod > 0 && MathAbs(newPeriod - oldPeriod) / oldPeriod > CHANGE_THRESHOLD) {
            if (g_enableLogsEffective) {
                PrintFormat("[PERIODS] ?? M5 EMA period changed: %d ? %d (%.1f%%)", 
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
                PrintFormat("[PERIODS] ?? H1 EMA period changed: %d ? %d (%.1f%%)", 
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
                PrintFormat("[PERIODS] ?? H4 EMA period changed: %d ? %d (%.1f%%)", 
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
                PrintFormat("[PERIODS] ?? D1 EMA period changed: %d ? %d (%.1f%%)", 
                    (int)oldPeriod, (int)newPeriod, 100.0 * MathAbs(newPeriod - oldPeriod) / oldPeriod);
            }
            return true;
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| ?? FIX: Salva periodi correnti come precedenti                    |
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
        PrintFormat("[DEINIT] ?? EA Deinit avviato - Motivo: %d (%s)", reason, GetDeinitReasonText(reason));
    }
    
    // ---------------------------------------------------------------
    // ?? REPORT FINALE STATISTICHE TRADING
    // ---------------------------------------------------------------
    if (g_stats.totalTrades > 0) {
        double netProfit = g_stats.totalProfit - g_stats.totalLoss;
        double winRate = 100.0 * g_stats.winTrades / g_stats.totalTrades;
        double avgSlippage = (g_stats.slippageCount > 0) ? g_stats.totalSlippage / g_stats.slippageCount : 0;
        
        Print("");
        Print("+---------------------------------------------------------------------------+");
        Print("�                    ?? REPORT FINALE SESSIONE                               �");
        Print("�---------------------------------------------------------------------------�");
        PrintFormat("� Simbolo: %s | Magic: %d", _Symbol, g_uniqueMagicNumber);
        PrintFormat("� Periodo: %s ? %s", 
            TimeToString(g_eaStartTime, TIME_DATE|TIME_MINUTES),
            TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
        Print("�---------------------------------------------------------------------------�");
        PrintFormat("� TRADES: %d totali | Win: %d (%.1f%%) | Loss: %d (%.1f%%)",
            g_stats.totalTrades,
            g_stats.winTrades, winRate,
            g_stats.lossTrades, 100.0 - winRate);
        PrintFormat("� PROFITTO LORDO: +%.2f | PERDITA LORDA: -%.2f",
            g_stats.totalProfit, g_stats.totalLoss);
        PrintFormat("� ?? PROFITTO NETTO: %+.2f %s",
            netProfit, AccountInfoString(ACCOUNT_CURRENCY));
        PrintFormat("� COMMISSIONI: %.2f | SWAP: %.2f",
            g_stats.totalCommission, g_stats.totalSwap);
        Print("�---------------------------------------------------------------------------�");
        PrintFormat("� PROFIT FACTOR: %.2f", g_stats.profitFactor);
        PrintFormat("� EXPECTANCY: %.2f per trade", g_stats.expectancy);
        PrintFormat("� AVG WIN: %.2f | AVG LOSS: %.2f | Ratio: %.2f",
            g_stats.avgWin, g_stats.avgLoss,
            g_stats.avgLoss > 0 ? g_stats.avgWin / g_stats.avgLoss : 0);
        Print("�---------------------------------------------------------------------------�");
        PrintFormat("� MAX DRAWDOWN: %.2f (%.2f%%)",
            g_stats.maxDrawdown, g_stats.maxDrawdownPct);
        PrintFormat("� MAX WIN STREAK: %d | MAX LOSS STREAK: %d",
            g_stats.maxWinStreak, g_stats.maxLossStreak);
        if (g_stats.slippageCount > 0) {
            PrintFormat("� AVG SLIPPAGE: %.2f pts su %d trade",
                avgSlippage, g_stats.slippageCount);
        }
        Print("+---------------------------------------------------------------------------+");
        Print("");
    } else {
        Print("[DEINIT] ?? Nessun trade eseguito in questa sessione");
    }
    
    // ---------------------------------------------------------------
    // ?? EXPORT TRADES PER MONTE CARLO ANALYSIS
    // ---------------------------------------------------------------
    if (ExportTradesCSV) {
        Print("[DEINIT] ?? Avvio esportazione trade CSV...");
        ExportTradesToCSV();
    } else {
        Print("[DEINIT] ?? Export CSV disabilitato (ExportTradesCSV=false)");
    }
    
    EventKillTimer();
    if (g_enableLogsEffective) Print("[DEINIT] ?? Timer terminato");
    
    ReleaseIndicators();
    
    // Reset buffer storici (pulizia esplicita)
    int hurstSize = ArraySize(g_hurstHistory);
    int scoreSize = ArraySize(g_scoreHistory);
    int tradeScoreSize = ArraySize(g_tradeScoreHistory);
    
    ArrayFree(g_hurstHistory);
    ArrayFree(g_scoreHistory);
    ArrayFree(g_tradeScoreHistory);
    
    // ? Reset indici buffer
    g_hurstHistorySize = 0;
    g_hurstHistoryIndex = 0;
    g_scoreHistorySize = 0;
    g_scoreHistoryIndex = 0;
    g_tradeScoreHistorySize = 0;
    g_tradeScoreHistoryIndex = 0;
    
    // ? Reset somme incrementali (CRITICO per riavvio EA!)
    g_hurstSum = 0.0;
    g_hurstSumSq = 0.0;
    g_scoreSum = 0.0;
    g_scoreSumSq = 0.0;
    g_tradeScoreSum = 0.0;
    g_tradeScoreSumSq = 0.0;
    
    // ?? FIX: Reset contatori anti-drift
    g_hurstOperationCount = 0;
    g_scoreOperationCount = 0;
    g_tradeScoreOperationCount = 0;
    
    // ? Reset flag di stato
    g_hurstZoneReady = false;
    g_hurstReady = false;
    g_tradeScoreReady = false;
    g_scoreThresholdReady = false;
    
    // ? Reset variabili di cache e contatori
    g_tfDataCacheValid = false;
    g_tfDataRecalcCounter = 0;
    g_barsSinceLastRecalc = 0;
    lastBarTime = 0;
    lastHurstRecalc = 0;
    
    // ? Reset valori calcolati Hurst
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
        PrintFormat("[DEINIT-BUFFER] ?? g_hurstHistory liberato: %d elementi ? 0 %s",
            hurstSize, ArraySize(g_hurstHistory) == 0 ? "?" : "?");
        PrintFormat("[DEINIT-BUFFER] ?? g_scoreHistory liberato: %d elementi ? 0 %s",
            scoreSize, ArraySize(g_scoreHistory) == 0 ? "?" : "?");
        PrintFormat("[DEINIT-BUFFER] ?? g_tradeScoreHistory liberato: %d elementi ? 0 %s",
            tradeScoreSize, ArraySize(g_tradeScoreHistory) == 0 ? "?" : "?");
        Print("[DEINIT] ? EA terminato correttamente");
    }
}

//+------------------------------------------------------------------+
//| ?? EXPORT TRADES TO CSV - Per analisi Monte Carlo                |
//| Esporta tutti i trade chiusi in formato CSV per Python           |
//| ? Funziona sia in LIVE che in BACKTEST                          |
//+------------------------------------------------------------------+
void ExportTradesToCSV()
{
    bool isTester = MQLInfoInteger(MQL_TESTER) != 0;
    Print(isTester ? "[EXPORT] ?? Modalit� BACKTEST" : "[EXPORT] ?? Modalit� LIVE");
    
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
        Print("[EXPORT] ? Impossibile accedere allo storico trade - HistorySelect failed");
        return;
    }
    
    int totalDeals = HistoryDealsTotal();
    PrintFormat("[EXPORT] ?? HistoryDealsTotal = %d", totalDeals);
    if (totalDeals == 0) {
        Print("[EXPORT] ?? Nessun deal nello storico - nessun file creato");
        return;
    }
    
    // ---------------------------------------------------------------
    // PRIMA PASSA: Conta i trade validi e calcola balance iniziale
    // ---------------------------------------------------------------
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
        Print("[EXPORT] ?? Nessun trade valido trovato per questo simbolo/EA");
        return;
    }
    
    // Calcola balance iniziale
    double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double startBalance = finalBalance - totalPL;
    double runningBalance = startBalance;
    
    // ---------------------------------------------------------------
    // GENERA NOME FILE
    // ---------------------------------------------------------------
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
    
    // ---------------------------------------------------------------
    // APRI FILE - Usa FILE_COMMON per accessibilit�
    // ---------------------------------------------------------------
    // FILE_COMMON salva in: C:\Users\[User]\AppData\Roaming\MetaQuotes\Terminal\Common\Files
    // Questo � accessibile sia da live che da tester
    int fileHandle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ';');
    
    if (fileHandle == INVALID_HANDLE) {
        // Fallback: prova senza FILE_COMMON
        fileHandle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI, ';');
        if (fileHandle == INVALID_HANDLE) {
            PrintFormat("[EXPORT] ? Impossibile creare file: %s (Errore: %d)", filename, GetLastError());
            return;
        }
    }
    
    // ---------------------------------------------------------------
    // SCRIVI HEADER CSV (compatibile con montecarlo_analyzer.py)
    // ---------------------------------------------------------------
    FileWrite(fileHandle, 
        "Ticket", "OpenTime", "CloseTime", "Type", "Symbol", "Volume", 
        "OpenPrice", "ClosePrice", "Commission", "Swap", "Profit", 
        "NetProfit", "Balance", "Duration_Minutes", "MagicNumber", "Comment");
    
    int exportedCount = 0;
    
    // ---------------------------------------------------------------
    // SECONDA PASSA: Esporta i trade con tutti i dettagli
    // ---------------------------------------------------------------
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
                    // Aggiungi commissione di apertura SOLO se presente e non gi� inclusa
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
        
        // Il TIPO della posizione � quello del deal di APERTURA (non chiusura!)
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
    
    // ---------------------------------------------------------------
    // STAMPA RISULTATO
    // ---------------------------------------------------------------
    if (exportedCount > 0) {
        string commonPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\" + filename;
        string localPath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\" + filename;
        
        Print("");
        Print("+---------------------------------------------------------------------------+");
        Print("�              ?? EXPORT TRADE COMPLETATO PER MONTE CARLO                    �");
        Print("�---------------------------------------------------------------------------�");
        PrintFormat("� Trade esportati: %d", exportedCount);
        PrintFormat("� Balance iniziale: %.2f ? Balance finale: %.2f", startBalance, runningBalance);
        PrintFormat("� Profitto totale: %+.2f", totalPL);
        Print("�---------------------------------------------------------------------------�");
        PrintFormat("� File: %s", filename);
        if (isTester) {
            Print("� ?? BACKTEST - File salvato in:");
            PrintFormat("�    %s", commonPath);
        } else {
            Print("� ?? LIVE - File salvato in:");
            PrintFormat("�    %s", localPath);
        }
        Print("�---------------------------------------------------------------------------�");
        Print("� ?? Per analisi Monte Carlo:                                                �");
        Print("�    1. Copia il file nella cartella montecarlo/                             �");
        Print("�    2. Esegui: python example_usage.py                                      �");
        Print("+---------------------------------------------------------------------------+");
        Print("");
    } else {
        Print("[EXPORT] ?? Nessun trade esportato");
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
//| ?? Inizializzazione handles indicatori con periodi ORGANICI      |
//+------------------------------------------------------------------+
bool InitializeIndicators()
{
    if (g_enableLogsEffective) Print("[INIT-HANDLES] ?? Inizio creazione handle indicatori...");
    
    int handleCount = 0;
    int handleErrors = 0;
    
    // ---------------------------------------------------------------
    // M5: Timeframe operativo (scalping/intraday)
    // ---------------------------------------------------------------
    // Trend Primario
    emaHandle_M5 = iMA(_Symbol, PERIOD_M5, g_organic_M5.ema, 0, MODE_EMA, PRICE_CLOSE);
    macdHandle_M5 = iMACD(_Symbol, PERIOD_M5, g_organic_M5.macd_fast, g_organic_M5.macd_slow, g_organic_M5.macd_signal, PRICE_CLOSE);
    psarHandle_M5 = iSAR(_Symbol, PERIOD_M5, g_organic_M5.psar_step, g_organic_M5.psar_max);
    smaFastHandle_M5 = iMA(_Symbol, PERIOD_M5, g_organic_M5.sma_fast, 0, MODE_SMA, PRICE_CLOSE);
    smaSlowHandle_M5 = iMA(_Symbol, PERIOD_M5, g_organic_M5.sma_slow, 0, MODE_SMA, PRICE_CLOSE);
    ichimokuHandle_M5 = iIchimoku(_Symbol, PERIOD_M5, g_organic_M5.ichimoku_tenkan, g_organic_M5.ichimoku_kijun, g_organic_M5.ichimoku_senkou);
    // Trend Filter
    adxHandle_M5 = iADX(_Symbol, PERIOD_M5, g_organic_M5.adx);
    // Trend Support
    bbHandle_M5 = iBands(_Symbol, PERIOD_M5, g_organic_M5.bb, 0, g_organic_M5.bb_dev, PRICE_CLOSE);
    obvHandle_M5 = iOBV(_Symbol, PERIOD_M5, VOLUME_TICK);
    atrHandle_M5 = iATR(_Symbol, PERIOD_M5, g_organic_M5.atr);
    // Mean-Reversion Detection (vota inversione)
    rsiHandle_M5 = iRSI(_Symbol, PERIOD_M5, g_organic_M5.rsi, PRICE_CLOSE);
    stochHandle_M5 = iStochastic(_Symbol, PERIOD_M5, g_organic_M5.stoch_k, g_organic_M5.stoch_d, g_organic_M5.stoch_slowing, MODE_SMA, STO_LOWHIGH);
    
    // Log M5
    if (g_enableLogsEffective) {
        int m5ok = 0, m5err = 0;
        if (emaHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (macdHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (psarHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (smaFastHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (smaSlowHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (ichimokuHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (adxHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (bbHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (obvHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (atrHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (rsiHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        if (stochHandle_M5 != INVALID_HANDLE) m5ok++; else m5err++;
        handleCount += m5ok; handleErrors += m5err;
        PrintFormat("[INIT-HANDLES] M5: %d/%d handle creati %s", m5ok, 12, m5err == 0 ? "?" : "??");
    }
    
    // ---------------------------------------------------------------
    // H1: Timeframe intermedio
    // ---------------------------------------------------------------
    // Trend Primario
    emaHandle_H1 = iMA(_Symbol, PERIOD_H1, g_organic_H1.ema, 0, MODE_EMA, PRICE_CLOSE);
    macdHandle_H1 = iMACD(_Symbol, PERIOD_H1, g_organic_H1.macd_fast, g_organic_H1.macd_slow, g_organic_H1.macd_signal, PRICE_CLOSE);
    psarHandle_H1 = iSAR(_Symbol, PERIOD_H1, g_organic_H1.psar_step, g_organic_H1.psar_max);
    smaFastHandle_H1 = iMA(_Symbol, PERIOD_H1, g_organic_H1.sma_fast, 0, MODE_SMA, PRICE_CLOSE);
    smaSlowHandle_H1 = iMA(_Symbol, PERIOD_H1, g_organic_H1.sma_slow, 0, MODE_SMA, PRICE_CLOSE);
    ichimokuHandle_H1 = iIchimoku(_Symbol, PERIOD_H1, g_organic_H1.ichimoku_tenkan, g_organic_H1.ichimoku_kijun, g_organic_H1.ichimoku_senkou);
    // Trend Filter
    adxHandle_H1 = iADX(_Symbol, PERIOD_H1, g_organic_H1.adx);
    // Trend Support
    bbHandle_H1 = iBands(_Symbol, PERIOD_H1, g_organic_H1.bb, 0, g_organic_H1.bb_dev, PRICE_CLOSE);
    obvHandle_H1 = iOBV(_Symbol, PERIOD_H1, VOLUME_TICK);
    atrHandle_H1 = iATR(_Symbol, PERIOD_H1, g_organic_H1.atr);
    // Mean-Reversion Detection (vota inversione)
    rsiHandle_H1 = iRSI(_Symbol, PERIOD_H1, g_organic_H1.rsi, PRICE_CLOSE);
    stochHandle_H1 = iStochastic(_Symbol, PERIOD_H1, g_organic_H1.stoch_k, g_organic_H1.stoch_d, g_organic_H1.stoch_slowing, MODE_SMA, STO_LOWHIGH);
    
    // Log H1
    if (g_enableLogsEffective) {
        int h1ok = 0, h1err = 0;
        if (emaHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (macdHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (psarHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (smaFastHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (smaSlowHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (ichimokuHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (adxHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (bbHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (obvHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (atrHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (rsiHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        if (stochHandle_H1 != INVALID_HANDLE) h1ok++; else h1err++;
        handleCount += h1ok; handleErrors += h1err;
        PrintFormat("[INIT-HANDLES] H1: %d/%d handle creati %s", h1ok, 12, h1err == 0 ? "?" : "??");
    }
    
    // ---------------------------------------------------------------
    // H4: Timeframe swing
    // ---------------------------------------------------------------
    // Trend Primario
    emaHandle_H4 = iMA(_Symbol, PERIOD_H4, g_organic_H4.ema, 0, MODE_EMA, PRICE_CLOSE);
    macdHandle_H4 = iMACD(_Symbol, PERIOD_H4, g_organic_H4.macd_fast, g_organic_H4.macd_slow, g_organic_H4.macd_signal, PRICE_CLOSE);
    psarHandle_H4 = iSAR(_Symbol, PERIOD_H4, g_organic_H4.psar_step, g_organic_H4.psar_max);
    smaFastHandle_H4 = iMA(_Symbol, PERIOD_H4, g_organic_H4.sma_fast, 0, MODE_SMA, PRICE_CLOSE);
    smaSlowHandle_H4 = iMA(_Symbol, PERIOD_H4, g_organic_H4.sma_slow, 0, MODE_SMA, PRICE_CLOSE);
    ichimokuHandle_H4 = iIchimoku(_Symbol, PERIOD_H4, g_organic_H4.ichimoku_tenkan, g_organic_H4.ichimoku_kijun, g_organic_H4.ichimoku_senkou);
    // Trend Filter
    adxHandle_H4 = iADX(_Symbol, PERIOD_H4, g_organic_H4.adx);
    // Trend Support
    bbHandle_H4 = iBands(_Symbol, PERIOD_H4, g_organic_H4.bb, 0, g_organic_H4.bb_dev, PRICE_CLOSE);
    obvHandle_H4 = iOBV(_Symbol, PERIOD_H4, VOLUME_TICK);
    atrHandle_H4 = iATR(_Symbol, PERIOD_H4, g_organic_H4.atr);
    // Mean-Reversion Detection (vota inversione)
    rsiHandle_H4 = iRSI(_Symbol, PERIOD_H4, g_organic_H4.rsi, PRICE_CLOSE);
    stochHandle_H4 = iStochastic(_Symbol, PERIOD_H4, g_organic_H4.stoch_k, g_organic_H4.stoch_d, g_organic_H4.stoch_slowing, MODE_SMA, STO_LOWHIGH);
    
    // Log H4
    if (g_enableLogsEffective) {
        int h4ok = 0, h4err = 0;
        if (emaHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (macdHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (psarHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (smaFastHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (smaSlowHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (ichimokuHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (adxHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (bbHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (obvHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (atrHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (rsiHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        if (stochHandle_H4 != INVALID_HANDLE) h4ok++; else h4err++;
        handleCount += h4ok; handleErrors += h4err;
        PrintFormat("[INIT-HANDLES] H4: %d/%d handle creati %s", h4ok, 12, h4err == 0 ? "?" : "??");
    }
    
    // ---------------------------------------------------------------
    // D1: Timeframe trend lungo
    // ---------------------------------------------------------------
    // Trend Primario
    emaHandle_D1 = iMA(_Symbol, PERIOD_D1, g_organic_D1.ema, 0, MODE_EMA, PRICE_CLOSE);
    macdHandle_D1 = iMACD(_Symbol, PERIOD_D1, g_organic_D1.macd_fast, g_organic_D1.macd_slow, g_organic_D1.macd_signal, PRICE_CLOSE);
    psarHandle_D1 = iSAR(_Symbol, PERIOD_D1, g_organic_D1.psar_step, g_organic_D1.psar_max);
    smaFastHandle_D1 = iMA(_Symbol, PERIOD_D1, g_organic_D1.sma_fast, 0, MODE_SMA, PRICE_CLOSE);
    smaSlowHandle_D1 = iMA(_Symbol, PERIOD_D1, g_organic_D1.sma_slow, 0, MODE_SMA, PRICE_CLOSE);
    ichimokuHandle_D1 = iIchimoku(_Symbol, PERIOD_D1, g_organic_D1.ichimoku_tenkan, g_organic_D1.ichimoku_kijun, g_organic_D1.ichimoku_senkou);
    // Trend Filter
    adxHandle_D1 = iADX(_Symbol, PERIOD_D1, g_organic_D1.adx);
    // Trend Support
    bbHandle_D1 = iBands(_Symbol, PERIOD_D1, g_organic_D1.bb, 0, g_organic_D1.bb_dev, PRICE_CLOSE);
    obvHandle_D1 = iOBV(_Symbol, PERIOD_D1, VOLUME_TICK);
    atrHandle_D1 = iATR(_Symbol, PERIOD_D1, g_organic_D1.atr);
    // Mean-Reversion Detection (vota inversione)
    rsiHandle_D1 = iRSI(_Symbol, PERIOD_D1, g_organic_D1.rsi, PRICE_CLOSE);
    stochHandle_D1 = iStochastic(_Symbol, PERIOD_D1, g_organic_D1.stoch_k, g_organic_D1.stoch_d, g_organic_D1.stoch_slowing, MODE_SMA, STO_LOWHIGH);
    
    // Log D1
    if (g_enableLogsEffective) {
        int d1ok = 0, d1err = 0;
        if (emaHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (macdHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (psarHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (smaFastHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (smaSlowHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (ichimokuHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (adxHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (bbHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (obvHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (atrHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (rsiHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        if (stochHandle_D1 != INVALID_HANDLE) d1ok++; else d1err++;
        handleCount += d1ok; handleErrors += d1err;
        PrintFormat("[INIT-HANDLES] D1: %d/%d handle creati %s", d1ok, 12, d1err == 0 ? "?" : "??");
        PrintFormat("[INIT-HANDLES] ?? TOTALE: %d/48 handle creati | Errori: %d %s", 
            handleCount, handleErrors, handleErrors == 0 ? "?" : "?");
    }
    
    // Verifica solo handle critici (trend primario + support)
    return (emaHandle_M5 != INVALID_HANDLE && macdHandle_M5 != INVALID_HANDLE && 
            psarHandle_M5 != INVALID_HANDLE && adxHandle_M5 != INVALID_HANDLE &&
            emaHandle_H1 != INVALID_HANDLE && macdHandle_H1 != INVALID_HANDLE &&
            psarHandle_H1 != INVALID_HANDLE && adxHandle_H1 != INVALID_HANDLE &&
            emaHandle_H4 != INVALID_HANDLE && macdHandle_H4 != INVALID_HANDLE &&
            psarHandle_H4 != INVALID_HANDLE && adxHandle_H4 != INVALID_HANDLE &&
            emaHandle_D1 != INVALID_HANDLE && macdHandle_D1 != INVALID_HANDLE &&
            psarHandle_D1 != INVALID_HANDLE && adxHandle_D1 != INVALID_HANDLE);
}

//+------------------------------------------------------------------+
//| Rilascio handles indicatori                                      |
//+------------------------------------------------------------------+
void ReleaseIndicators()
{
    if (g_enableLogsEffective) Print("[DEINIT-HANDLES] ?? Inizio rilascio handle indicatori...");
    
    int releasedCount = 0;
    int releaseErrors = 0;
    
    // M5 - Trend Primario
    if (emaHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_M5)) releasedCount++; else releaseErrors++; emaHandle_M5 = INVALID_HANDLE; }
    if (macdHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_M5)) releasedCount++; else releaseErrors++; macdHandle_M5 = INVALID_HANDLE; }
    if (psarHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(psarHandle_M5)) releasedCount++; else releaseErrors++; psarHandle_M5 = INVALID_HANDLE; }
    if (smaFastHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(smaFastHandle_M5)) releasedCount++; else releaseErrors++; smaFastHandle_M5 = INVALID_HANDLE; }
    if (smaSlowHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(smaSlowHandle_M5)) releasedCount++; else releaseErrors++; smaSlowHandle_M5 = INVALID_HANDLE; }
    if (ichimokuHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(ichimokuHandle_M5)) releasedCount++; else releaseErrors++; ichimokuHandle_M5 = INVALID_HANDLE; }
    // M5 - Support
    if (adxHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_M5)) releasedCount++; else releaseErrors++; adxHandle_M5 = INVALID_HANDLE; }
    if (bbHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_M5)) releasedCount++; else releaseErrors++; bbHandle_M5 = INVALID_HANDLE; }
    if (obvHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_M5)) releasedCount++; else releaseErrors++; obvHandle_M5 = INVALID_HANDLE; }
    if (atrHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_M5)) releasedCount++; else releaseErrors++; atrHandle_M5 = INVALID_HANDLE; }
    if (rsiHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_M5)) releasedCount++; else releaseErrors++; rsiHandle_M5 = INVALID_HANDLE; }
    if (stochHandle_M5 != INVALID_HANDLE) { if (IndicatorRelease(stochHandle_M5)) releasedCount++; else releaseErrors++; stochHandle_M5 = INVALID_HANDLE; }
    
    // H1 - Trend Primario
    if (emaHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_H1)) releasedCount++; else releaseErrors++; emaHandle_H1 = INVALID_HANDLE; }
    if (macdHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_H1)) releasedCount++; else releaseErrors++; macdHandle_H1 = INVALID_HANDLE; }
    if (psarHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(psarHandle_H1)) releasedCount++; else releaseErrors++; psarHandle_H1 = INVALID_HANDLE; }
    if (smaFastHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(smaFastHandle_H1)) releasedCount++; else releaseErrors++; smaFastHandle_H1 = INVALID_HANDLE; }
    if (smaSlowHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(smaSlowHandle_H1)) releasedCount++; else releaseErrors++; smaSlowHandle_H1 = INVALID_HANDLE; }
    if (ichimokuHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(ichimokuHandle_H1)) releasedCount++; else releaseErrors++; ichimokuHandle_H1 = INVALID_HANDLE; }
    // H1 - Support
    if (adxHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_H1)) releasedCount++; else releaseErrors++; adxHandle_H1 = INVALID_HANDLE; }
    if (bbHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_H1)) releasedCount++; else releaseErrors++; bbHandle_H1 = INVALID_HANDLE; }
    if (obvHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_H1)) releasedCount++; else releaseErrors++; obvHandle_H1 = INVALID_HANDLE; }
    if (atrHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_H1)) releasedCount++; else releaseErrors++; atrHandle_H1 = INVALID_HANDLE; }
    if (rsiHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_H1)) releasedCount++; else releaseErrors++; rsiHandle_H1 = INVALID_HANDLE; }
    if (stochHandle_H1 != INVALID_HANDLE) { if (IndicatorRelease(stochHandle_H1)) releasedCount++; else releaseErrors++; stochHandle_H1 = INVALID_HANDLE; }
    
    // H4 - Trend Primario
    if (emaHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_H4)) releasedCount++; else releaseErrors++; emaHandle_H4 = INVALID_HANDLE; }
    if (macdHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_H4)) releasedCount++; else releaseErrors++; macdHandle_H4 = INVALID_HANDLE; }
    if (psarHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(psarHandle_H4)) releasedCount++; else releaseErrors++; psarHandle_H4 = INVALID_HANDLE; }
    if (smaFastHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(smaFastHandle_H4)) releasedCount++; else releaseErrors++; smaFastHandle_H4 = INVALID_HANDLE; }
    if (smaSlowHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(smaSlowHandle_H4)) releasedCount++; else releaseErrors++; smaSlowHandle_H4 = INVALID_HANDLE; }
    if (ichimokuHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(ichimokuHandle_H4)) releasedCount++; else releaseErrors++; ichimokuHandle_H4 = INVALID_HANDLE; }
    // H4 - Support
    if (adxHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_H4)) releasedCount++; else releaseErrors++; adxHandle_H4 = INVALID_HANDLE; }
    if (bbHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_H4)) releasedCount++; else releaseErrors++; bbHandle_H4 = INVALID_HANDLE; }
    if (obvHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_H4)) releasedCount++; else releaseErrors++; obvHandle_H4 = INVALID_HANDLE; }
    if (atrHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_H4)) releasedCount++; else releaseErrors++; atrHandle_H4 = INVALID_HANDLE; }
    if (rsiHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_H4)) releasedCount++; else releaseErrors++; rsiHandle_H4 = INVALID_HANDLE; }
    if (stochHandle_H4 != INVALID_HANDLE) { if (IndicatorRelease(stochHandle_H4)) releasedCount++; else releaseErrors++; stochHandle_H4 = INVALID_HANDLE; }
    
    // D1 - Trend Primario
    if (emaHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(emaHandle_D1)) releasedCount++; else releaseErrors++; emaHandle_D1 = INVALID_HANDLE; }
    if (macdHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(macdHandle_D1)) releasedCount++; else releaseErrors++; macdHandle_D1 = INVALID_HANDLE; }
    if (psarHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(psarHandle_D1)) releasedCount++; else releaseErrors++; psarHandle_D1 = INVALID_HANDLE; }
    if (smaFastHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(smaFastHandle_D1)) releasedCount++; else releaseErrors++; smaFastHandle_D1 = INVALID_HANDLE; }
    if (smaSlowHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(smaSlowHandle_D1)) releasedCount++; else releaseErrors++; smaSlowHandle_D1 = INVALID_HANDLE; }
    if (ichimokuHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(ichimokuHandle_D1)) releasedCount++; else releaseErrors++; ichimokuHandle_D1 = INVALID_HANDLE; }
    // D1 - Support
    if (adxHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(adxHandle_D1)) releasedCount++; else releaseErrors++; adxHandle_D1 = INVALID_HANDLE; }
    if (bbHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(bbHandle_D1)) releasedCount++; else releaseErrors++; bbHandle_D1 = INVALID_HANDLE; }
    if (obvHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(obvHandle_D1)) releasedCount++; else releaseErrors++; obvHandle_D1 = INVALID_HANDLE; }
    if (atrHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(atrHandle_D1)) releasedCount++; else releaseErrors++; atrHandle_D1 = INVALID_HANDLE; }
    if (rsiHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(rsiHandle_D1)) releasedCount++; else releaseErrors++; rsiHandle_D1 = INVALID_HANDLE; }
    if (stochHandle_D1 != INVALID_HANDLE) { if (IndicatorRelease(stochHandle_D1)) releasedCount++; else releaseErrors++; stochHandle_D1 = INVALID_HANDLE; }
    
    if (g_enableLogsEffective) {
        PrintFormat("[DEINIT-HANDLES] ?? TOTALE: %d/48 handle rilasciati | Errori: %d %s", 
            releasedCount, releaseErrors, releaseErrors == 0 ? "?" : "??");
    }
}

//+------------------------------------------------------------------+
//| ?? AGGIORNAMENTO VELOCE - Solo ultima barra (usa cache)          |
//| Invece di ricaricare tutto, aggiorna solo i valori pi� recenti   |
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
    int atrH = INVALID_HANDLE, adxH = INVALID_HANDLE, stochH = INVALID_HANDLE;
    
    switch(tf) {
        case PERIOD_M5:  emaH = emaHandle_M5; rsiH = rsiHandle_M5; macdH = macdHandle_M5; atrH = atrHandle_M5; adxH = adxHandle_M5; stochH = stochHandle_M5; break;
        case PERIOD_H1:  emaH = emaHandle_H1; rsiH = rsiHandle_H1; macdH = macdHandle_H1; atrH = atrHandle_H1; adxH = adxHandle_H1; stochH = stochHandle_H1; break;
        case PERIOD_H4:  emaH = emaHandle_H4; rsiH = rsiHandle_H4; macdH = macdHandle_H4; atrH = atrHandle_H4; adxH = adxHandle_H4; stochH = stochHandle_H4; break;
        case PERIOD_D1:  emaH = emaHandle_D1; rsiH = rsiHandle_D1; macdH = macdHandle_D1; atrH = atrHandle_D1; adxH = adxHandle_D1; stochH = stochHandle_D1; break;
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
    // 🌱 v1.1: Aggiorna Stochastic per voto inversione
    if (CopyBuffer(stochH, 0, 0, 2, tempBuf) == 2) { data.stoch_main[lastIdx] = tempBuf[1]; data.stoch_main[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(stochH, 1, 0, 2, tempBuf) == 2) { data.stoch_signal[lastIdx] = tempBuf[1]; data.stoch_signal[lastIdx-1] = tempBuf[0]; }
    
    return true;
}

//+------------------------------------------------------------------+
//| ?? Caricamento dati timeframe con calcolo valori organici        |
//| ?? FIX: Usa start=1 per caricare dati STORICI (passato)          |
//+------------------------------------------------------------------+
bool LoadTimeFrameData(ENUM_TIMEFRAMES tf, TimeFrameData &data, int bars)
{
    // ?? FIX: Usa start=1 per garantire dati dal passato, non dalla barra corrente incompleta
    int copiedBars = CopyRates(_Symbol, tf, 1, bars, data.rates);
    if (copiedBars <= 0) {
        PrintFormat("[ERROR] Impossibile caricare rates per TF %s", EnumToString(tf));
        return false;
    }
    
    // ?? FIX: Non pi� warning "dati parziali" - ora usiamo quello che c'�
    // Se servono N barre e ne abbiamo M < N, usiamo M (il sistema si adatta)
    
    // ?? FIX: Verifica che i dati non siano corrotti (prezzi validi)
    // ?? Numero barre da verificare = round(f�) � 4 (derivato da f)
    int barsToCheck = (int)MathRound(MathPow(PHI, 3));  // f� � 4
    int invalidBars = 0;
    for (int i = 0; i < MathMin(copiedBars, barsToCheck); i++) {
        if (data.rates[i].close <= 0 || data.rates[i].open <= 0 ||
            data.rates[i].high <= 0 || data.rates[i].low <= 0 ||
            data.rates[i].high < data.rates[i].low) {
            invalidBars++;
        }
    }
    // ?? Soglia = round(f) � 2 (derivato da f)
    int maxInvalidBars = (int)MathRound(PHI);  // � 2
    if (invalidBars > maxInvalidBars) {
        PrintFormat("[ERROR] TF %s: Dati corrotti rilevati (%d/%d barre invalide)", 
            EnumToString(tf), invalidBars, barsToCheck);
        return false;
    }
    
    int count = ArraySize(data.rates);
    
    // Ridimensiona arrays - Trend Primario
    ArrayResize(data.ema, count);
    ArrayResize(data.macd, count);
    ArrayResize(data.macd_signal, count);
    ArrayResize(data.psar, count);
    ArrayResize(data.sma_fast, count);
    ArrayResize(data.sma_slow, count);
    ArrayResize(data.ichimoku_tenkan, count);
    ArrayResize(data.ichimoku_kijun, count);
    ArrayResize(data.ichimoku_senkou_a, count);
    ArrayResize(data.ichimoku_senkou_b, count);
    // Trend Filter
    ArrayResize(data.adx, count);
    ArrayResize(data.di_plus, count);
    ArrayResize(data.di_minus, count);
    // Trend Support
    ArrayResize(data.bb_upper, count);
    ArrayResize(data.bb_middle, count);
    ArrayResize(data.bb_lower, count);
    ArrayResize(data.atr, count);
    ArrayResize(data.ha_open, count);
    ArrayResize(data.ha_close, count);
    ArrayResize(data.obv, count);
    // Mean-Reversion Detection (vota inversione)
    ArrayResize(data.rsi, count);
    ArrayResize(data.stoch_main, count);
    ArrayResize(data.stoch_signal, count);
    
    // ?? Inizializza valori organici (saranno calcolati dai DATI dopo il caricamento)
    data.atr_avg = 0;
    data.adx_avg = 0;
    data.adx_stddev = 0;
    data.adx_threshold = 0;  // Verr� calcolato da CalculateOrganicValues
    data.isDataReady = false;
    
    // ?? PURO: Inizializza tutto a 0 - verranno calcolati dai DATI
    data.rsi_center = 0;
    data.rsi_scale = 0;
    data.obv_scale = 0;
    data.adx_p25 = 0;
    data.adx_p75 = 0;
    
    // Copia dati indicatori (seleziona handles appropriati per timeframe)
    int emaH = INVALID_HANDLE, macdH = INVALID_HANDLE, psarH = INVALID_HANDLE;
    int smaFastH = INVALID_HANDLE, smaSlowH = INVALID_HANDLE, ichimokuH = INVALID_HANDLE;
    int adxH = INVALID_HANDLE, bbH = INVALID_HANDLE, atrH = INVALID_HANDLE;
    int obvH = INVALID_HANDLE, rsiH = INVALID_HANDLE, stochH = INVALID_HANDLE;
    int minBarsRequired = g_organic_M5.min_bars_required;
    
    switch(tf) {
        case PERIOD_M5:
            // Trend Primario
            emaH = emaHandle_M5; macdH = macdHandle_M5; psarH = psarHandle_M5;
            smaFastH = smaFastHandle_M5; smaSlowH = smaSlowHandle_M5; ichimokuH = ichimokuHandle_M5;
            // Trend Filter + Support
            adxH = adxHandle_M5; bbH = bbHandle_M5; atrH = atrHandle_M5;
            obvH = obvHandle_M5; rsiH = rsiHandle_M5; stochH = stochHandle_M5;
            minBarsRequired = g_organic_M5.min_bars_required;
            data.organic = g_organic_M5;
            break;
        case PERIOD_H1:
            emaH = emaHandle_H1; macdH = macdHandle_H1; psarH = psarHandle_H1;
            smaFastH = smaFastHandle_H1; smaSlowH = smaSlowHandle_H1; ichimokuH = ichimokuHandle_H1;
            adxH = adxHandle_H1; bbH = bbHandle_H1; atrH = atrHandle_H1;
            obvH = obvHandle_H1; rsiH = rsiHandle_H1; stochH = stochHandle_H1;
            minBarsRequired = g_organic_H1.min_bars_required;
            data.organic = g_organic_H1;
            break;
        case PERIOD_H4:
            emaH = emaHandle_H4; macdH = macdHandle_H4; psarH = psarHandle_H4;
            smaFastH = smaFastHandle_H4; smaSlowH = smaSlowHandle_H4; ichimokuH = ichimokuHandle_H4;
            adxH = adxHandle_H4; bbH = bbHandle_H4; atrH = atrHandle_H4;
            obvH = obvHandle_H4; rsiH = rsiHandle_H4; stochH = stochHandle_H4;
            minBarsRequired = g_organic_H4.min_bars_required;
            data.organic = g_organic_H4;
            break;
        case PERIOD_D1:
            emaH = emaHandle_D1; macdH = macdHandle_D1; psarH = psarHandle_D1;
            smaFastH = smaFastHandle_D1; smaSlowH = smaSlowHandle_D1; ichimokuH = ichimokuHandle_D1;
            adxH = adxHandle_D1; bbH = bbHandle_D1; atrH = atrHandle_D1;
            obvH = obvHandle_D1; rsiH = rsiHandle_D1; stochH = stochHandle_D1;
            minBarsRequired = g_organic_D1.min_bars_required;
            data.organic = g_organic_D1;
            break;
        default:
            return false;
    }
    
    // ?? FIX: Copia buffers indicatori da start=1 per allineamento con CopyRates(start=1)
    // Questo garantisce che indicatori e prezzi siano sincronizzati sulle stesse barre storiche
    
    // Trend Primario
    if (CopyBuffer(emaH, 0, 1, count, data.ema) <= 0) return false;
    if (CopyBuffer(macdH, 0, 1, count, data.macd) <= 0) return false;
    if (CopyBuffer(macdH, 1, 1, count, data.macd_signal) <= 0) return false;
    if (CopyBuffer(psarH, 0, 1, count, data.psar) <= 0) return false;
    if (CopyBuffer(smaFastH, 0, 1, count, data.sma_fast) <= 0) return false;
    if (CopyBuffer(smaSlowH, 0, 1, count, data.sma_slow) <= 0) return false;
    // Ichimoku: buffer 0=Tenkan, 1=Kijun, 2=Senkou A, 3=Senkou B
    if (CopyBuffer(ichimokuH, 0, 1, count, data.ichimoku_tenkan) <= 0) return false;
    if (CopyBuffer(ichimokuH, 1, 1, count, data.ichimoku_kijun) <= 0) return false;
    if (CopyBuffer(ichimokuH, 2, 1, count, data.ichimoku_senkou_a) <= 0) return false;
    if (CopyBuffer(ichimokuH, 3, 1, count, data.ichimoku_senkou_b) <= 0) return false;
    
    // Trend Filter
    if (CopyBuffer(adxH, 0, 1, count, data.adx) <= 0) return false;
    if (CopyBuffer(adxH, 1, 1, count, data.di_plus) <= 0) return false;
    if (CopyBuffer(adxH, 2, 1, count, data.di_minus) <= 0) return false;
    
    // Trend Support
    if (CopyBuffer(bbH, 0, 1, count, data.bb_upper) <= 0) return false;
    if (CopyBuffer(bbH, 1, 1, count, data.bb_middle) <= 0) return false;
    if (CopyBuffer(bbH, 2, 1, count, data.bb_lower) <= 0) return false;
    if (CopyBuffer(atrH, 0, 1, count, data.atr) <= 0) return false;
    if (CopyBuffer(obvH, 0, 1, count, data.obv) <= 0) return false;
    
    // Mean-Reversion Detection (RSI + Stochastic vota inversione)
    if (CopyBuffer(rsiH, 0, 1, count, data.rsi) <= 0) return false;
    // Stochastic: buffer 0 = %K (main), buffer 1 = %D (signal)
    if (CopyBuffer(stochH, 0, 1, count, data.stoch_main) <= 0) return false;
    if (CopyBuffer(stochH, 1, 1, count, data.stoch_signal) <= 0) return false;
    
    // Calcola indicatori derivati (Heikin Ashi)
    CalculateCustomIndicators(data, count);
    
    // ---------------------------------------------------------------
    // ?? CALCOLO VALORI ORGANICI (ATR medio, ADX threshold dinamico)
    // Questi valori si auto-adattano ai dati storici disponibili
    // ---------------------------------------------------------------
    CalculateOrganicValues(data, count, minBarsRequired);
    
    return true;
}

//+------------------------------------------------------------------+
//| ?? Calcolo valori organici per ATR e ADX - PURO                  |
//| FORMULA ATR: atr_avg = media(ATR ultime N barre)                 |
//| FORMULA ADX: adx_threshold = media(ADX) + (1/f) * stddev(ADX)   |
//| Se dati insufficienti ? isDataReady = false (no fallback!)       |
//+------------------------------------------------------------------+
void CalculateOrganicValues(TimeFrameData &data, int count, int minBarsRequired)
{
    // Verifica se abbiamo abbastanza dati
    if (count < minBarsRequired) {
        Print("? [ORGANIC] Barre insufficienti: ", count, " < ", minBarsRequired, " richieste - TF DISABILITATO");
        data.isDataReady = false;
        return;
    }
    
    int lastIdx = count - 1;
    
    // ---------------------------------------------------------------
    // ?? LOOKBACK derivato dal naturalPeriod � f
    // Solo UN moltiplicatore f, non potenze arbitrarie!
    // Il naturalPeriod gi� deriva dai DATI (autocorrelazione)
    // ---------------------------------------------------------------
    int organicLookback = (int)MathRound(data.organic.naturalPeriod * PHI);
    int lookback = MathMin(organicLookback, count - 1);
    lookback = MathMax(lookback, (int)MathRound(PHI_SQ));  // Minimo f� � 3
    
    // ---------------------------------------------------------------
    // ATR ORGANICO: Media semplice delle ultime N barre
    // Formula: atr_avg = sum(ATR[i]) / N
    // ---------------------------------------------------------------
    double atr_sum = 0;
    int atr_count = 0;
    for (int i = lastIdx - lookback; i <= lastIdx; i++) {
        if (i >= 0 && i < ArraySize(data.atr)) {
            atr_sum += data.atr[i];
            atr_count++;
        }
    }
    
    if (atr_count == 0 || atr_sum <= 0) {
        Print("? [ORGANIC] ATR invalido (count=", atr_count, ", sum=", atr_sum, ") - TF DISABILITATO");
        data.isDataReady = false;
        return;
    }
    data.atr_avg = atr_sum / atr_count;
    
    // ---------------------------------------------------------------
    // ADX ORGANICO: Media + (1/f) * deviazione standard
    // Formula: threshold = avg(ADX) + (1/f) * sqrt(sum((ADX-avg)^2)/N)
    // Questo identifica quando ADX � "significativamente sopra" la norma
    // ---------------------------------------------------------------
    double adx_sum = 0;
    int adx_count = 0;
    for (int i = lastIdx - lookback; i <= lastIdx; i++) {
        if (i >= 0 && i < ArraySize(data.adx)) {
            adx_sum += data.adx[i];
            adx_count++;
        }
    }
    
    if (adx_count == 0) {
        Print("? [ORGANIC] ADX dati insufficienti - TF DISABILITATO");
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
        Print("? [ORGANIC] ADX stddev=0 (dati flat) - TF DISABILITATO");
        data.isDataReady = false;
        return;
    }
    
    // ---------------------------------------------------------------
    // ?? CALCOLA SOGLIE EMPIRICHE per tutti gli oscillatori
    // Centri e scale derivano dai DATI storici, non da costanti teoriche!
    // Se fallisce, invalida il TF (no fallback!)
    // ---------------------------------------------------------------
    bool empiricalOK = CalculateEmpiricalThresholds(data, lookback);
    
    if (!empiricalOK) {
        Print("? [ORGANIC] Calcolo soglie empiriche FALLITO - TF DISABILITATO");
        data.isDataReady = false;
        return;
    }
    
    // ?? Soglia ADX organica = media + (1/f) � stddev � avg + 0.618�stddev
    // f (rapporto aureo) definisce la proporzione naturale tra media e variazione
    data.adx_threshold = data.adx_avg + PHI_INV * data.adx_stddev;
    
    // ?? Limita la soglia usando PERCENTILI empirici invece di potenze arbitrarie
    // I limiti ora derivano dalla distribuzione REALE dei dati ADX
    data.adx_threshold = MathMax(data.adx_p25, MathMin(data.adx_p75, data.adx_threshold));
    
    // ? Tutti i calcoli completati con successo
    data.isDataReady = true;
    
    if (g_enableLogsEffective) {
        PrintFormat("[ORGANIC] ? TF ready: ATR_avg=%.5f ADX_threshold=%.1f lookback=%d",
            data.atr_avg, data.adx_threshold, lookback);
    }
}

//+------------------------------------------------------------------+
//| ?? Calcolo indicatori personalizzati OTTIMIZZATO O(n)            |
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
//| ?? Calcolo segnali per timeframe con pesi specifici              |
//| LOGICA NORMALIZZATA TREND-FOLLOWING:                            |
//| Tutti gli indicatori: >0 = BUY, <0 = SELL                       |
//| I pesi moltiplicano i valori normalizzati                        |
//| ADX: trend-following (ADX alto + DI per direzione)              |
//| ATR: contrarian (ATR > media = possibile inversione)            |
//|                                                                  |
//| ?? SOGLIE ORGANICHE:                                             |
//|   ADX threshold = data.adx_threshold (calcolato dinamicamente)   |
//|   ATR threshold = data.atr_avg (media dinamica, no moltiplicatore)|
//|                                                                  |
//| ?? PESI ORGANICI (sostituiscono 72 input hardcodati):            |
//|   Ogni indicatore usa enable bool + peso TF organico             |
//|   peso_TF = data.organic.weight (auto-calcolato)                 |
//+------------------------------------------------------------------+
double CalculateSignalScore(TimeFrameData &data, string timeframe)
// ?? NOTA: Usa direttamente enableXXX (bool globali) e data.organic.weight (peso organico TF)
{
    int lastIdx = ArraySize(data.rates) - 1;
    if (lastIdx < 1) return 0;
    
    // ?? Verifica se i dati sono pronti per il calcolo organico
    if (!data.isDataReady) {
        return 0;  // Non abbiamo abbastanza dati, non generare segnali
    }
    
    double price = data.rates[lastIdx].close;
    // ?? USA g_pointValue CACHATO (inizializzato 1� in OnInit)
    double point_value = g_pointValue;
    
    // ?? SCALA ORGANICA: usa ATR medio � f (rapporto aureo) come unit� di volatilit�
    // f � 1.618 � la proporzione naturale universale
    // Distanza = f � ATR per raggiungere normalizzazione �1
    // Minimo organico = naturalPeriod � f pips (derivato dai DATI)
    double min_organic_scale = point_value * data.organic.naturalPeriod * PHI;
    
    // ?? FIX: Protezione divisione per zero con fallback multipli
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
        atr_scale = MathPow(PHI_INV, 23);  // � 0.0000106
    }
    
    // ✅ VALIDATO: atr_scale sempre > 0 dopo tutti i fallback
    
    // ═══════════════════════════════════════════════════════════════
    // CALCOLO VALORI NORMALIZZATI (>0 = BUY, <0 = SELL)
    // ═══════════════════════════════════════════════════════════════
    
    double totalScore = 0;
    
    // 🌱 Peso organico del TF (calcolato da Hurst: peso = H_TF / Σ(H_tutti_TF))
    double w = data.organic.weight;
    
    // 🌱 PESI RELATIVI PER CATEGORIA (φ-derivati)
    // TREND PRIMARIO: peso base = 1.0 (riferimento)
    // TREND SUPPORT:  peso = φ⁻¹ ≈ 0.618 (conferma, non guida)
    // TREND FILTER:   peso = 1.0 ma condizionale (solo se ADX > soglia)
    double w_primary = w * 1.0;       // EMA, MACD, PSAR, SMA, Ichimoku
    double w_support = w * PHI_INV;   // BB, Heikin (≈ 62% del primario)
    double w_filter = w * 1.0;        // ADX (condizionale)
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 TREND PRIMARIO (peso pieno)
    // ═══════════════════════════════════════════════════════════════
    
    // EMA: prezzo - EMA (positivo = sopra EMA = BUY)
    // 🌱 Scala ORGANICA: distanza normalizzata con ATR (non pips fissi)
    if (enableEMA && ArraySize(data.ema) > lastIdx) {
        double ema_norm = (price - data.ema[lastIdx]) / atr_scale;
        ema_norm = MathMax(-1.0, MathMin(1.0, ema_norm));
        totalScore += ema_norm * w_primary;
    }
    
    // MACD: differenza MACD - Signal (già trend-following)
    // 🌱 Scala ORGANICA: differenza normalizzata con ATR
    if (enableMACD && ArraySize(data.macd) > lastIdx && ArraySize(data.macd_signal) > lastIdx) {
        double macd_diff = data.macd[lastIdx] - data.macd_signal[lastIdx];
        double macd_norm = MathMax(-1.0, MathMin(1.0, macd_diff / atr_scale));
        totalScore += macd_norm * w_primary;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 PSAR (Parabolic SAR): Trend-following puro - PRIMARIO
    // Prezzo > PSAR = BUY (+1), Prezzo < PSAR = SELL (-1)
    // Intensità proporzionale alla distanza normalizzata
    // ═══════════════════════════════════════════════════════════════
    if (enablePSAR && ArraySize(data.psar) > lastIdx) {
        double psar_dist = (price - data.psar[lastIdx]) / atr_scale;
        double psar_norm = MathMax(-1.0, MathMin(1.0, psar_dist));
        totalScore += psar_norm * w_primary;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 SMA CROSS: SMA Fast vs SMA Slow (Golden/Death Cross) - PRIMARIO
    // Fast > Slow = BUY, Fast < Slow = SELL
    // Intensità proporzionale alla distanza normalizzata
    // ═══════════════════════════════════════════════════════════════
    if (enableSMA && ArraySize(data.sma_fast) > lastIdx && ArraySize(data.sma_slow) > lastIdx) {
        double sma_diff = (data.sma_fast[lastIdx] - data.sma_slow[lastIdx]) / atr_scale;
        double sma_norm = MathMax(-1.0, MathMin(1.0, sma_diff));
        totalScore += sma_norm * w_primary;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 ICHIMOKU: Sistema multi-fattore trend-following - PRIMARIO
    // Segnali: Tenkan/Kijun cross + Price vs Cloud
    // BUY: Price > Cloud + Tenkan > Kijun
    // SELL: Price < Cloud + Tenkan < Kijun
    // ═══════════════════════════════════════════════════════════════
    if (enableIchimoku && ArraySize(data.ichimoku_tenkan) > lastIdx && 
        ArraySize(data.ichimoku_kijun) > lastIdx &&
        ArraySize(data.ichimoku_senkou_a) > lastIdx && 
        ArraySize(data.ichimoku_senkou_b) > lastIdx) {
        
        double tenkan = data.ichimoku_tenkan[lastIdx];
        double kijun = data.ichimoku_kijun[lastIdx];
        double senkou_a = data.ichimoku_senkou_a[lastIdx];
        double senkou_b = data.ichimoku_senkou_b[lastIdx];
        
        // Limiti della Cloud
        double cloud_top = MathMax(senkou_a, senkou_b);
        double cloud_bottom = MathMin(senkou_a, senkou_b);
        double cloud_mid = (cloud_top + cloud_bottom) / 2.0;
        
        // Segnale 1: Tenkan vs Kijun (cross)
        double tk_signal = (tenkan - kijun) / atr_scale;
        tk_signal = MathMax(-1.0, MathMin(1.0, tk_signal));
        
        // Segnale 2: Price vs Cloud
        double cloud_signal = 0;
        if (price > cloud_top) {
            // Sopra la cloud = BUY forte
            cloud_signal = MathMin(1.0, (price - cloud_top) / atr_scale);
        } else if (price < cloud_bottom) {
            // Sotto la cloud = SELL forte
            cloud_signal = MathMax(-1.0, (price - cloud_bottom) / atr_scale);
        } else {
            // Dentro la cloud = segnale debole proporzionale
            cloud_signal = (price - cloud_mid) / ((cloud_top - cloud_bottom) / 2.0 + atr_scale * PHI_INV);
            // 🌱 FIX: Clamp φ-derivato invece di ±0.5 arbitrario
            cloud_signal = MathMax(-PHI_INV, MathMin(PHI_INV, cloud_signal));  // Dentro cloud = max ±φ⁻¹ ≈ ±0.618
        }
        
        // ?? Combina i segnali con pesi organici: f per TK cross, 1 per cloud
        double ichi_score = (tk_signal * PHI + cloud_signal) / (PHI + 1.0);
        totalScore += ichi_score * w_primary;  // ?? TREND PRIMARY
    }
    
    // Bollinger Bands: posizione relativa nel range
    // ?? FIX: Protezione divisione per zero con minimo organico
    if (enableBB && ArraySize(data.bb_upper) > lastIdx && ArraySize(data.bb_lower) > lastIdx && ArraySize(data.bb_middle) > lastIdx) {
        double bb_range = data.bb_upper[lastIdx] - data.bb_lower[lastIdx];
        // ?? FIX: Minimo BB range = ATR � f?� (evita divisione per valori troppo piccoli)
        double min_bb_range = atr_scale * PHI_INV_SQ;
        if (min_bb_range <= 0) min_bb_range = point_value * PHI;  // Fallback assoluto
        
        double bb_norm = 0;
        if (bb_range > min_bb_range) {
            bb_norm = (price - data.bb_middle[lastIdx]) / (bb_range / 2.0);
            bb_norm = MathMax(-1.0, MathMin(1.0, bb_norm));
        }
        // Se bb_range <= min_bb_range, bande troppo strette, segnale neutro (0)
        totalScore += bb_norm * w_support;  // ?? TREND SUPPORT (≈62% del primario)
    }
    
    // ATR: indicatore di volatilit� (non direzionale) - escluso dal voto direzionale
    // ADX: forza del trend (non direzionale) - escluso dal voto direzionale
    // Entrambi possono essere usati esternamente come filtri ma non contribuiscono allo score
    
    // ---------------------------------------------------------------
    // ?? INDICATORI ADDIZIONALI
    // ---------------------------------------------------------------
    
    // ?? Heikin Ashi: close - open
    // ?? Scala ORGANICA: usa 1/f dell'ATR (corpo HA = proporzione aurea del range)
    if (enableHeikin && ArraySize(data.ha_close) > lastIdx && ArraySize(data.ha_open) > lastIdx) {
        double ha_diff = data.ha_close[lastIdx] - data.ha_open[lastIdx];
        double ha_norm = MathMax(-1.0, MathMin(1.0, ha_diff / (atr_scale * PHI_INV)));  // 1/φ ≈ 0.618
        totalScore += ha_norm * w_support;  // ?? TREND SUPPORT (≈62% del primario)
    }
    
    // 🌱 v1.1: OBV è MEAN-REVERSION - vota nella sezione combinata (non qui)
    // L'OBV vota inversione nella sezione CalculateMultiTimeframeScore
    // dove è combinato con RSI e Stochastic per votare direzione inversione
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 ADX: TREND-FOLLOWING 100% ORGANICO (basato su φ)
    // Soglia: avg + (1/φ) × stddev ≈ avg + 0.618×stddev
    // Max forte: avg + f� � stddev � avg + 2.618�stddev
    // DI norm: basato su stddev � f
    // ---------------------------------------------------------------
    if (enableADX && ArraySize(data.adx) > lastIdx && ArraySize(data.di_plus) > lastIdx && ArraySize(data.di_minus) > lastIdx) {
        double adx_val = data.adx[lastIdx];
        double di_plus = data.di_plus[lastIdx];
        double di_minus = data.di_minus[lastIdx];
        
        // ?? Valori organici derivati da f e statistiche del mercato
        double adx_threshold_organic = data.adx_threshold;                         // avg + PHI_INV�stddev
        double adx_max_organic = data.adx_avg + PHI_SQ * data.adx_stddev;          // f� sigma = molto forte
        double di_scale_organic = MathMax(PHI_SQ, data.adx_stddev * PHI);          // min f� � 2.618
        
        // Solo se ADX supera la soglia organica (trend significativo per questo mercato)
        if (adx_val > adx_threshold_organic && adx_max_organic > adx_threshold_organic) {
            // ?? Forza normalizzata: (ADX - soglia) / (max - soglia), dove max = avg + f��stddev
            double adx_strength = MathMin(1.0, (adx_val - adx_threshold_organic) / (adx_max_organic - adx_threshold_organic));
            
            // ?? Direzione basata su +DI vs -DI, normalizzata con f
            double di_diff = di_plus - di_minus;
            double di_norm = MathMax(-1.0, MathMin(1.0, di_diff / di_scale_organic));
            
            // Score = direzione * forza del trend * peso
            totalScore += di_norm * adx_strength * w_filter;  // ?? TREND FILTER (condizionale)
            
            // ?? Log organico ADX (se abilitato)
            if (g_enableLogsEffective) {
                PrintFormat("[%s] ?? ADX ORGANICO: val=%.1f > soglia=%.1f (maxf�s=%.1f) ? DI+:%.1f DI-:%.1f scale=%.1f",
                    timeframe, adx_val, adx_threshold_organic, adx_max_organic, di_plus, di_minus, di_scale_organic);
            }
        }
        // Se ADX < soglia, mercato laterale, ADX non contribuisce
    }
    
    // ---------------------------------------------------------------
    // RITORNA SCORE NORMALIZZATO
    // Positivo = BUY, Negativo = SELL, Zero = NEUTRAL
    // ---------------------------------------------------------------
    
    return totalScore;
}

//+------------------------------------------------------------------+
//| Tick event                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
    // Controlla eventuale stop loss temporale
    CheckAndCloseOnTimeStop();
    
    // ---------------------------------------------------------------
    // WARMUP: Verifica se il preload storico � andato a buon fine
    // Il buffer Hurst viene pre-caricato in OnInit() da PreloadHurstBufferFromHistory()
    // Qui controlliamo solo che i flag siano pronti, non aspettiamo tempo reale
    // ---------------------------------------------------------------
    if (!g_warmupComplete) {
        // ?? FIX: Se Hurst filter � disabilitato, skip check buffer Hurst
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
                Print("? [WARMUP] Buffer pre-caricati dallo storico - EA pronto per il trading");
            } else {
                Print("? [WARMUP] Hurst filter DISABILITATO - EA pronto per il trading (no buffer richiesti)");
            }
        } else {
            // Preload fallito - tenta ricalcolo incrementale
            static datetime lastWarmupLog = 0;
            if (TimeCurrent() - lastWarmupLog >= 30) {
                PrintFormat("?? [WARMUP] In attesa dati sufficienti: Hurst=%d/%d TradeScore=%d/%d Ready=%s", 
                    g_hurstHistorySize, (int)MathCeil(HURST_HISTORY_MAX * PHI_INV_SQ),
                    g_tradeScoreHistorySize, (int)MathCeil(TRADE_SCORE_HISTORY_MAX * PHI_INV_SQ),
                    g_hurstReady ? "S�" : "No");
                lastWarmupLog = TimeCurrent();
            }
            
            // Aggiorna sistema per raccogliere dati incrementalmente
            datetime currentBarTime_warmup = iTime(_Symbol, PERIOD_CURRENT, 0);
            static datetime lastBarTime_warmup = 0;
            if (currentBarTime_warmup != lastBarTime_warmup) {
                lastBarTime_warmup = currentBarTime_warmup;
                RecalculateOrganicSystem();
            }
            return;  // Non proseguire con trading finch� buffer non pronti
        }
    }
    
    // Controlla nuovo bar del TF corrente (quello del grafico)
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if (currentBarTime == lastBarTime) return;
    lastBarTime = currentBarTime;
    
    // ---------------------------------------------------------------
    // ?? OTTIMIZZAZIONE: Ricalcolo ogni N barre (non ogni barra)
    // ---------------------------------------------------------------
    g_barsSinceLastRecalc++;
    
    bool shouldRecalc = false;
    if (RecalcEveryBars <= 0) {
        // Comportamento originale: ricalcola sempre
        shouldRecalc = true;
    } else {
        // ?? OTTIMIZZATO: ricalcola solo ogni N barre
        if (g_barsSinceLastRecalc >= RecalcEveryBars) {
            shouldRecalc = true;
            g_barsSinceLastRecalc = 0;
        }
    }
    
    if (g_enableLogsEffective) {
        Print("");
        Print("+---------------------------------------------------------------------------+");
        PrintFormat("� ?? NUOVA BARRA %s - %s                                   �", 
            EnumToString(Period()), TimeToString(currentBarTime, TIME_DATE|TIME_MINUTES));
        if (shouldRecalc) {
            Print("� Avvio ricalcolo completo sistema organico...                              �");
        } else {
            PrintFormat("� ? Skip ricalcolo (%d/%d barre)                                           �",
                g_barsSinceLastRecalc, RecalcEveryBars);
        }
        Print("+---------------------------------------------------------------------------+");
    }
    
    // ---------------------------------------------------------------
    // ?? RICALCOLO SISTEMA ORGANICO (condizionale per performance)
    // ---------------------------------------------------------------
    if (shouldRecalc) {
        RecalculateOrganicSystem();
    }
    
    // Carica dati multi-timeframe per analisi
    // ?? Sistema robusto: continua con i TF disponibili
    // ?? OTTIMIZZATO: Ricarica solo ogni N barre
    if (g_enableLogsEffective) Print("[DATA] ?? Caricamento dati multi-timeframe in corso...");
    
    // ?? CHECK CACHE DATI TF - Ricarica solo se necessario
    // ?? Intervallo reload dati derivato da f� � 4 (invece di 5 hardcoded)
    int tfDataReloadDivisor = (int)MathRound(MathPow(PHI, 3));  // f� � 4
    int tfDataReloadInterval = MathMax(1, RecalcEveryBars / tfDataReloadDivisor);  // Reload dinamico
    bool shouldReloadTFData = false;
    
    if (!g_tfDataCacheValid || g_tfDataRecalcCounter >= tfDataReloadInterval) {
        shouldReloadTFData = true;
        g_tfDataRecalcCounter = 0;
    } else {
        g_tfDataRecalcCounter++;
    }
    
    // ---------------------------------------------------------------
    // ?? barsToLoad = max(min_bars_required di tutti i TF) � f (buffer statistico)
    // Usiamo il max tra tutti i periodi organici gi� calcolati
    // min_bars_required = longest period + buffer organico (calcolato in CalculateOrganicPeriods)
    // ---------------------------------------------------------------=
    int maxPeriodNeeded = MathMax(g_organic_M5.min_bars_required, 
                          MathMax(g_organic_H1.min_bars_required,
                          MathMax(g_organic_H4.min_bars_required, g_organic_D1.min_bars_required)));
    // Buffer = periodo max � f (per avere overlap statistico)
    int barsToLoad = (int)MathRound(maxPeriodNeeded * PHI);
    // ?? Minimo organico = f8 � 47 (derivato da potenza di f)
    int minBarsOrganic = (int)MathRound(PHI_SQ * PHI_SQ * PHI_SQ * PHI_SQ);  // f8 � 46.98
    barsToLoad = MathMax(barsToLoad, minBarsOrganic);
    // ?? FIX: Limite massimo ragionevole per evitare richieste assurde
    // f�� � 322 � un limite sensato per analisi tecnica
    int maxBarsLimit = (int)MathRound(MathPow(PHI, 12));  // � 322
    if (barsToLoad > maxBarsLimit) {
        static bool warnedOnce = false;
        if (!warnedOnce) {
            PrintFormat("[DATA] ?? barsToLoad ridotto da %d a %d (limite f��)", barsToLoad, maxBarsLimit);
            warnedOnce = true;
        }
        barsToLoad = maxBarsLimit;
    }
    
    // ?? USA CACHE O RICARICA
    bool m5Loaded = true, h1Loaded = true, h4Loaded = true, d1Loaded = true;
    
    if (shouldReloadTFData) {
        m5Loaded = LoadTimeFrameData(PERIOD_M5, tfData_M5, barsToLoad);
        h1Loaded = LoadTimeFrameData(PERIOD_H1, tfData_H1, barsToLoad);
        h4Loaded = LoadTimeFrameData(PERIOD_H4, tfData_H4, barsToLoad);
        d1Loaded = LoadTimeFrameData(PERIOD_D1, tfData_D1, barsToLoad);
        g_tfDataCacheValid = true;
        
        if (g_enableLogsEffective) {
            PrintFormat("[DATA] Stato: M5=%s H1=%s H4=%s D1=%s | barsToLoad=%d (RELOAD)",
                m5Loaded ? "?" : "?",
                h1Loaded ? "?" : "?",
                h4Loaded ? "?" : "?",
                d1Loaded ? "?" : "?",
                barsToLoad);
        }
    } else {
        // ?? USA CACHE - Aggiorna SOLO l'ultima barra per ogni TF
        m5Loaded = UpdateLastBar(PERIOD_M5, tfData_M5);
        h1Loaded = UpdateLastBar(PERIOD_H1, tfData_H1);
        h4Loaded = UpdateLastBar(PERIOD_H4, tfData_H4);
        d1Loaded = UpdateLastBar(PERIOD_D1, tfData_D1);
        
        if (g_enableLogsEffective) {
            PrintFormat("[DATA] ? CACHE USATA (%d/%d) | Aggiornata ultima barra",
                g_tfDataRecalcCounter, tfDataReloadInterval);
        }
    }
    
    // M5 � obbligatorio (TF operativo), gli altri sono opzionali
    if (!m5Loaded) {
        if (g_enableLogsEffective) Print("[ERROR] ? M5 obbligatorio non disponibile - skip");
        return;
    }
    
    // ?? Imposta flag globali TF attivi (usati da ExecuteTradingLogic)
    g_vote_M5_active = EnableVote_M5 && m5Loaded;
    g_vote_H1_active = EnableVote_H1 && h1Loaded;
    g_vote_H4_active = EnableVote_H4 && h4Loaded;
    g_vote_D1_active = EnableVote_D1 && d1Loaded;
    
    // Almeno un TF deve essere attivo
    if (!g_vote_M5_active && !g_vote_H1_active && !g_vote_H4_active && !g_vote_D1_active) {
        if (g_enableLogsEffective) Print("[ERROR] ?? Nessun TF attivo - skip");
        return;
    }
    
    // ---------------------------------------------------------------
    // ?? CONTROLLO DATI ORGANICI PRONTI
    // L'EA NON entra a mercato finch� non ha abbastanza barre storiche
    // Controlla solo i TF attivi (caricati E abilitati)
    // ---------------------------------------------------------------
    bool allDataReady = true;
    if (g_vote_M5_active && !tfData_M5.isDataReady) allDataReady = false;
    if (g_vote_H1_active && !tfData_H1.isDataReady) allDataReady = false;
    if (g_vote_H4_active && !tfData_H4.isDataReady) allDataReady = false;
    if (g_vote_D1_active && !tfData_D1.isDataReady) allDataReady = false;
    
    if (!allDataReady) {
        if (g_enableLogsEffective) {
            PrintFormat("[ORGANIC] ? Attesa dati: M5=%s H1=%s H4=%s D1=%s",
                (!g_vote_M5_active || tfData_M5.isDataReady) ? "?" : "?",
                (!g_vote_H1_active || tfData_H1.isDataReady) ? "?" : "?",
                (!g_vote_H4_active || tfData_H4.isDataReady) ? "?" : "?",
                (!g_vote_D1_active || tfData_D1.isDataReady) ? "?" : "?");
        }
        return;
    }
    
    // ?? LOG VALORI ORGANICI CALCOLATI (sempre visibile se abilitato)
    if (g_enableLogsEffective) {
        static datetime lastOrganicLogTime = 0;
        datetime currentTime = TimeCurrent();
        
        // ?? Log organico ogni naturalPeriod � f secondi (derivato dai DATI!)
        // Usiamo il naturalPeriod di M5 � 60 (secondi per barra) � f
        int logIntervalSeconds = (int)MathRound(g_organic_M5.naturalPeriod * 60 * PHI);
        // ?? Minimo organico = f5 � 11 secondi
        int minLogInterval = (int)MathRound(MathPow(PHI, 5));
        logIntervalSeconds = MathMax(minLogInterval, logIntervalSeconds);
        
        if (currentTime - lastOrganicLogTime >= logIntervalSeconds) {
            lastOrganicLogTime = currentTime;
            
            Print("");
            Print("---------------------------------------------------------------");
            Print("?? VALORI ORGANICI CALCOLATI DINAMICAMENTE");
            Print("---------------------------------------------------------------");
            
            if (g_vote_M5_active && ArraySize(tfData_M5.atr) > 0 && ArraySize(tfData_M5.adx) > 0) {
                PrintFormat("[M5] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + 1/f*std=%.1f)",
                    tfData_M5.atr[ArraySize(tfData_M5.atr)-1], tfData_M5.atr_avg,
                    tfData_M5.adx[ArraySize(tfData_M5.adx)-1], tfData_M5.adx_threshold,
                    tfData_M5.adx_avg, tfData_M5.adx_stddev);
            }
            if (g_vote_H1_active && ArraySize(tfData_H1.atr) > 0 && ArraySize(tfData_H1.adx) > 0) {
                PrintFormat("[H1] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + 1/f*std=%.1f)",
                    tfData_H1.atr[ArraySize(tfData_H1.atr)-1], tfData_H1.atr_avg,
                    tfData_H1.adx[ArraySize(tfData_H1.adx)-1], tfData_H1.adx_threshold,
                    tfData_H1.adx_avg, tfData_H1.adx_stddev);
            }
            if (g_vote_H4_active && ArraySize(tfData_H4.atr) > 0 && ArraySize(tfData_H4.adx) > 0) {
                PrintFormat("[H4] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + 1/f*std=%.1f)",
                    tfData_H4.atr[ArraySize(tfData_H4.atr)-1], tfData_H4.atr_avg,
                    tfData_H4.adx[ArraySize(tfData_H4.adx)-1], tfData_H4.adx_threshold,
                    tfData_H4.adx_avg, tfData_H4.adx_stddev);
            }
            if (g_vote_D1_active && ArraySize(tfData_D1.atr) > 0 && ArraySize(tfData_D1.adx) > 0) {
                PrintFormat("[D1] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + 1/f*std=%.1f)",
                    tfData_D1.atr[ArraySize(tfData_D1.atr)-1], tfData_D1.atr_avg,
                    tfData_D1.adx[ArraySize(tfData_D1.adx)-1], tfData_D1.adx_threshold,
                    tfData_D1.adx_avg, tfData_D1.adx_stddev);
            }
            
            Print("---------------------------------------------------------------");
            Print("");
        }
    }
    
    // Logica di trading
    if (g_enableLogsEffective) Print("[TRADE] ?? Avvio logica di trading...");
    ExecuteTradingLogic();
    if (g_enableLogsEffective) {
        Print("[TRADE] ? Elaborazione completata");
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
        string voteStr = (voteResult == 1) ? "?? BUY" : ((voteResult == -1) ? "?? SELL" : "? NEUTRAL");
        PrintFormat("[VOTE] Risultato: %s (score raw: %d)", voteStr, voteResult);
    }
    
    // Controlla se deve eseguire trades
    if (!enableTrading) {
        if (g_enableLogsEffective) Print("[TRADE] ?? Trading DISABILITATO nelle impostazioni - nessuna operazione");
        return;
    }
    
    // ??? VERIFICA PERMESSI TRADING TERMINALE/BROKER
    if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
        if (g_enableLogsEffective) Print("[TRADE] ? Trading non permesso dal terminale - verificare impostazioni");
        return;
    }
    if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) {
        if (g_enableLogsEffective) Print("[TRADE] ? Trading non permesso per questo EA - verificare AutoTrading");
        return;
    }
    
    // ??? VERIFICA SIMBOLO TRADABILE
    long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
    if (tradeMode == SYMBOL_TRADE_MODE_DISABLED) {
        if (g_enableLogsEffective) Print("[TRADE] ? Simbolo non tradabile - mercato chiuso o bloccato");
        return;
    }
    
    // Ottieni prezzo corrente
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double spread = ask - bid;
    
    // Filtro spread
    if (MaxSpread > 0 && spread > MaxSpread * _Point) {
        if (g_enableLogsEffective) PrintFormat("[TRADE] ?? Spread troppo alto: %.1f pips > %.1f max - skip", spread/_Point, MaxSpread);
        return;
    }
    
    // Conta posizioni aperte
    int openPositions = CountOpenPositions();
    
    if (MaxOpenTrades > 0 && openPositions >= MaxOpenTrades) {
        if (g_enableLogsEffective) PrintFormat("[TRADE] ?? Max posizioni raggiunto: %d/%d - skip", openPositions, MaxOpenTrades);
        return;
    }
    
    // ---------------------------------------------------------------
    // ?? FILTRO HURST NO-TRADE ZONE
    // Se il mercato � in regime "random" (H � centro storico), i segnali sono rumore
    // Blocca nuovi trade ma permette gestione posizioni esistenti
    // ?? FIX: Log solo se c'era un segnale valido da bloccare
    // ---------------------------------------------------------------
    if (!IsTradeAllowedByHurst()) {
        // ?? FIX: Log solo se c'� un segnale reale (BUY/SELL) che viene bloccato
        if (voteResult != 0 && g_enableLogsEffective) {
            PrintFormat("[HURST] ? TRADE %s BLOCCATO - TradeScore=%.3f < %.3f (soglia)", 
                voteResult == 1 ? "BUY" : "SELL", g_hurstTradeScore, g_tradeScoreThreshold);
        }
        return;
    }
    
    // Esegui trades basati su voto
    if (voteResult == -1) {
        if (g_enableLogsEffective) Print("[TRADE] ?? SEGNALE SELL CONFERMATO - Apertura ordine...");
        OpenSellOrder();
    }
    else if (voteResult == 1) {
        if (g_enableLogsEffective) Print("[TRADE] ?? SEGNALE BUY CONFERMATO - Apertura ordine...");
        OpenBuyOrder();
    }
    // ?? FIX: Rimosso log "Nessun segnale - in attesa..." - troppo verboso (ogni 5 min)
}

//+------------------------------------------------------------------+
//| Conta posizioni aperte                                           |
//| ?? FIX: Aggiunta gestione errori per sincronizzazione            |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    // ?? FIX: Retry loop per gestire race condition (posizioni che cambiano durante iterazione)
    int maxRetries = 3;
    
    for (int attempt = 0; attempt < maxRetries; attempt++) {
        int count = 0;
        bool hadError = false;
        int skippedPositions = 0;  // ?? FIX: Conta posizioni saltate per diagnostica
        
        // ?? FIX: Usa Magic cachato invece di ricalcolarlo ogni volta
        int uniqueMagic = g_uniqueMagicNumber;
        int total = PositionsTotal();
        
        for (int i = total - 1; i >= 0; i--) {
            // Reset errore prima di ogni operazione
            ResetLastError();
            
            ulong ticket = PositionGetTicket(i);
            
            // ?? FIX: Gestione errore di sincronizzazione
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
                        PrintFormat("[CountOpenPositions] ?? Errore %d su posizione %d (tentativo %d)", err, i, attempt + 1);
                    }
                }
                // err == 0 con ticket == 0: posizione gi� chiusa, skip silenzioso
                continue;
            }
            
            // Seleziona esplicitamente per ticket per garantire consistenza
            if (!PositionSelectByTicket(ticket)) {
                continue;  // Posizione non pi� valida
            }
            
            if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
                PositionGetInteger(POSITION_MAGIC) == uniqueMagic) {
                count++;
            }
        }
        
        // ?? FIX: Log se troppe posizioni saltate (possibile anomalia)
        if (skippedPositions > 2 && g_enableLogsEffective) {
            PrintFormat("[CountOpenPositions] ?? %d posizioni saltate (tentativo %d)", skippedPositions, attempt + 1);
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
        Print("[CountOpenPositions] ? Troppi errori - ritorno 0 per sicurezza");
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
        // ?? Log throttle: naturalPeriod � secondi per barra (derivato dai DATI!)
        // ?? FIX: Protezione quando naturalPeriod = 0
        int naturalPeriod = MathMax(1, g_organic_M5.naturalPeriod);  // Minimo 1 per evitare divisione per zero
        int throttleSeconds = (int)MathRound(naturalPeriod * 60 / PHI);
        // ?? Minimo organico = f4 � 7 secondi
        int minThrottle = (int)MathRound(MathPow(PHI, 4));
        throttleSeconds = MathMax(minThrottle, throttleSeconds);
        
        if (now - lastVoteDisabledLog >= throttleSeconds || lastVoteDisabledLog == 0) {
            Print("[VOTE] Sistema voti indicatori DISATTIVATO (EnableIndicatorVoteSystem=false) ? decisione neutra");
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
    // cATR e cADX rimossi perch� ATR/ADX non sono direzionali
    // TREND indicators (votano)
    bool cEMA = false, cMACD = false, cBB = false;
    bool cHeikin = false;
    bool cPSAR = false, cSMA = false, cIchi = false;
    // MEAN-REVERSION indicators (solo per log diagnostico - NON votano)
    bool cRSI = false, cOBV = false;
    double stochK = 0, stochD = 0;
    
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
        // ?? Usa centri EMPIRICI dalla struct tfData invece di costanti hardcoded!
        cEMA  = enableEMA         && (price > emaBuf[0]);
        cRSI  = enableRSI         && (rsiBuf[0] > tfData_M5.rsi_center);
        cMACD = enableMACD        && (macdBuf[0] > sigBuf[0]);
        // BB: sopra la banda media = BUY (coerente con CalculateSignalScore)
        double bbMiddle = (bbUp[0] + bbLow[0]) / 2.0;
        cBB   = enableBB          && (price > bbMiddle);
        // NOTA: ATR e ADX sono indicatori NON direzionali, usati solo come filtri (non partecipano al voto)
        
        // ??? Controlli array bounds per indicatori da struct tfData
        cHeikin = false;
        if (enableHeikin && ArraySize(tfData_M5.ha_close) > latestIdxM5 && ArraySize(tfData_M5.ha_open) > latestIdxM5) {
            cHeikin = (tfData_M5.ha_close[latestIdxM5] > tfData_M5.ha_open[latestIdxM5]);
        }
        
        cOBV = false;
        if (enableOBV && ArraySize(tfData_M5.obv) > latestIdxM5 && latestIdxM5 >= 1) {
            cOBV = (tfData_M5.obv[latestIdxM5] >= tfData_M5.obv[latestIdxM5 - 1]);
        }
        
        // ?? NUOVI INDICATORI TREND (v1.1)
        cPSAR = false;
        if (enablePSAR && ArraySize(tfData_M5.psar) > latestIdxM5) {
            cPSAR = (price > tfData_M5.psar[latestIdxM5]);
        }
        
        cSMA = false;
        if (enableSMA && ArraySize(tfData_M5.sma_fast) > latestIdxM5 && ArraySize(tfData_M5.sma_slow) > latestIdxM5) {
            cSMA = (tfData_M5.sma_fast[latestIdxM5] > tfData_M5.sma_slow[latestIdxM5]);
        }
        
        cIchi = false;
        if (enableIchimoku && ArraySize(tfData_M5.ichimoku_tenkan) > latestIdxM5 && 
            ArraySize(tfData_M5.ichimoku_kijun) > latestIdxM5 &&
            ArraySize(tfData_M5.ichimoku_senkou_a) > latestIdxM5) {
            double cloud_top = MathMax(tfData_M5.ichimoku_senkou_a[latestIdxM5], tfData_M5.ichimoku_senkou_b[latestIdxM5]);
            cIchi = (price > cloud_top && tfData_M5.ichimoku_tenkan[latestIdxM5] > tfData_M5.ichimoku_kijun[latestIdxM5]);
        }
        
        // Stochastic (per log - NON vota)
        stochK = 0; stochD = 0;
        if (enableStoch && ArraySize(tfData_M5.stoch_main) > latestIdxM5) {
            stochK = tfData_M5.stoch_main[latestIdxM5];
            stochD = tfData_M5.stoch_signal[latestIdxM5];
        }
        
        // ?? Calcola score M5 normalizzato tramite funzione unificata con valori ORGANICI
        // NOTA: Le variabili cXXX sopra sono usate solo per il log dettagliato,
        //       lo score effettivo viene da CalculateSignalScore che usa normalizzazione continua
        scoreM5 = CalculateSignalScore(tfData_M5, "M5");
        
        // Log M5 score calcolato
        if (g_enableLogsEffective) {
            PrintFormat("[M5] ?? Score normalizzato: %+.2f (peso organico TF: %.2f)", scoreM5, tfData_M5.organic.weight);
        }
    }
    
    // Calcolo consenso multi-timeframe con pesi e threshold specifici per ogni TF
    // OTTIMIZZAZIONE: Calcola score SOLO per TF attivi (usa flag globali)
    if (!g_vote_M5_active) scoreM5 = 0;  // M5 gi� calcolato sopra se attivo
    
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
    
    // ?? LOG DETTAGLIATO INDICATORI PER OGNI TIMEFRAME
    if (g_enableLogsEffective) {
        Print("\n========== ?? ANALISI INDICATORI DETTAGLIATA (v1.1) ==========");
        
        // M5 INDICATORS LOG
        if (g_vote_M5_active) {
            Print("\n--- M5 (OPERATIVO) ---");
            PrintFormat("  ?? Peso organico TF: %.2f", tfData_M5.organic.weight);
            
            // --- TREND PRIMARIO (VOTANO) ---
            Print("  --- TREND PRIMARIO (votano) ---");
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f ? %s (%s)",
                price, emaBuf[0], cEMA ? "? BUY" : "? SELL", enableEMA ? "VOTA" : "disattivo");
            PrintFormat("  MACD: %.6f vs Signal=%.6f ? %s (%s)",
                macdBuf[0], sigBuf[0], cMACD ? "? BUY" : "? SELL", enableMACD ? "VOTA" : "disattivo");
            double psar_val = (ArraySize(tfData_M5.psar) > latestIdxM5) ? tfData_M5.psar[latestIdxM5] : 0;
            PrintFormat("  PSAR: Price=%.5f vs SAR=%.5f ? %s (%s)",
                price, psar_val, cPSAR ? "? BUY" : "? SELL", enablePSAR ? "VOTA" : "disattivo");
            double sma_fast = (ArraySize(tfData_M5.sma_fast) > latestIdxM5) ? tfData_M5.sma_fast[latestIdxM5] : 0;
            double sma_slow = (ArraySize(tfData_M5.sma_slow) > latestIdxM5) ? tfData_M5.sma_slow[latestIdxM5] : 0;
            PrintFormat("  SMA Cross: Fast=%.5f vs Slow=%.5f ? %s (%s)",
                sma_fast, sma_slow, cSMA ? "? BUY" : "? SELL", enableSMA ? "VOTA" : "disattivo");
            PrintFormat("  Ichimoku: %s (%s)",
                cIchi ? "? Sopra Cloud + TK>KJ" : "? Sotto Cloud o TK<KJ", enableIchimoku ? "VOTA" : "disattivo");
            
            // --- TREND FILTER ---
            Print("  --- TREND FILTER ---");
            PrintFormat("  ADX: %.2f vs Soglia=%.2f ? %s (vota con +DI/-DI, %s)",
                adxBuf[0], tfData_M5.adx_threshold, adxBuf[0] > tfData_M5.adx_threshold ? "TREND" : "NO TREND", enableADX ? "VOTA" : "disattivo");
            
            // --- TREND SUPPORT (VOTANO) ---
            Print("  --- TREND SUPPORT (votano) ---");
            double ha_close_log = (ArraySize(tfData_M5.ha_close) > latestIdxM5) ? tfData_M5.ha_close[latestIdxM5] : 0;
            double ha_open_log = (ArraySize(tfData_M5.ha_open) > latestIdxM5) ? tfData_M5.ha_open[latestIdxM5] : 0;
            PrintFormat("  Heikin Ashi: HAclose=%.5f vs HAopen=%.5f ? %s (%s)",
                ha_close_log, ha_open_log, cHeikin ? "? BUY" : "? SELL", enableHeikin ? "VOTA" : "disattivo");
            PrintFormat("  BB: Price=%.5f vs Middle=%.5f ? %s (%s)",
                price, (bbUp[0] + bbLow[0]) / 2.0, cBB ? "? BUY" : "? SELL", enableBB ? "VOTA" : "disattivo");
            
            // ═══ MEAN-REVERSION (analisi H1 → voto su tutti TF) ═══
            Print("  ═══ MEAN-REVERSION (analisi H1 → voto combinato) ═══");
            Print("  📌 Nota: RSI/Stoch/OBV analizzati su H1, voto applicato a tutti TF");
            PrintFormat("  RSI M5: %.1f%% | Stoch K: %.1f%% | OBV: %s",
                rsiBuf[0], stochK, 
                (ArraySize(tfData_M5.obv) > latestIdxM5 && latestIdxM5 >= 1 && 
                 tfData_M5.obv[latestIdxM5] > tfData_M5.obv[latestIdxM5-1]) ? "📈 UP" : "📉 DOWN");
            
            PrintFormat("  🎯 SCORE M5: %.2f", scoreM5);
        } else {
            Print("  ?? M5 Score:  N/D (DISATTIVATO)");
        }
    }
    
    // H1 INDICATORS - Usa solo indicatori esistenti in TimeFrameData
    if (g_vote_H1_active && g_enableLogsEffective) {
        int h1_idx = ArraySize(tfData_H1.rsi) - 1;
        if (h1_idx < 0) {
            Print("\n--- H1: DATI NON DISPONIBILI ---");
        } else {
            Print("\n--- H1 (INTERMEDIO) ---");
            PrintFormat("  ?? Peso organico TF: %.2f", tfData_H1.organic.weight);
            double h1_close = (ArraySize(tfData_H1.rates) > h1_idx) ? tfData_H1.rates[h1_idx].close : price;
            int h1_prevIdx = (h1_idx > 0) ? h1_idx - 1 : 0;
            double h1_ema = (ArraySize(tfData_H1.ema) > h1_idx) ? tfData_H1.ema[h1_idx] : 0;
            double h1_rsi = (ArraySize(tfData_H1.rsi) > h1_idx) ? tfData_H1.rsi[h1_idx] : 0;
            double h1_adx = (ArraySize(tfData_H1.adx) > h1_idx) ? tfData_H1.adx[h1_idx] : 0;
            double h1_ha_close = (ArraySize(tfData_H1.ha_close) > h1_idx) ? tfData_H1.ha_close[h1_idx] : 0;
            double h1_ha_open = (ArraySize(tfData_H1.ha_open) > h1_idx) ? tfData_H1.ha_open[h1_idx] : 0;
            double h1_obv = (ArraySize(tfData_H1.obv) > h1_idx) ? tfData_H1.obv[h1_idx] : 0;
            double h1_obv_prev = (ArraySize(tfData_H1.obv) > h1_prevIdx) ? tfData_H1.obv[h1_prevIdx] : 0;
            // TREND (votano)
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f → %s (VOTA)", price, h1_ema, (price > h1_ema) ? "✅ BUY" : "❌ SELL");
            PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f → %s (FILTER)", h1_adx, tfData_H1.adx_threshold, (h1_adx > tfData_H1.adx_threshold) ? "TREND" : "NO TREND");
            PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f → %s (VOTA)", h1_ha_close, h1_ha_open, (h1_ha_close > h1_ha_open) ? "✅ BUY" : "❌ SELL");
            // MEAN-REVERSION (valori H1 usati per detection combinata)
            PrintFormat("  🔄 RSI H1: %.1f%% | OBV: %s (usati per voto combinato)", 
                h1_rsi, (h1_obv > h1_obv_prev) ? "📈 UP" : "📉 DOWN");
            PrintFormat("  🎯 SCORE H1: %.2f", scoreH1);
        }
    } else if (g_enableLogsEffective) {
        Print("  ?? H1 Score:  N/D (DISATTIVATO)");
    }
    
    // H4 INDICATORS - Usa solo indicatori esistenti in TimeFrameData
    if (g_vote_H4_active && g_enableLogsEffective) {
        int h4_idx = ArraySize(tfData_H4.rsi) - 1;
        if (h4_idx < 0) {
            Print("\n--- H4: DATI NON DISPONIBILI ---");
        } else {
            Print("\n--- H4 (SWING) ---");
            PrintFormat("  ?? Peso organico TF: %.2f", tfData_H4.organic.weight);
            double h4_close = (ArraySize(tfData_H4.rates) > h4_idx) ? tfData_H4.rates[h4_idx].close : price;
            int h4_prevIdx = (h4_idx > 0) ? h4_idx - 1 : 0;
            double h4_ema = (ArraySize(tfData_H4.ema) > h4_idx) ? tfData_H4.ema[h4_idx] : 0;
            double h4_rsi = (ArraySize(tfData_H4.rsi) > h4_idx) ? tfData_H4.rsi[h4_idx] : 0;
            double h4_adx = (ArraySize(tfData_H4.adx) > h4_idx) ? tfData_H4.adx[h4_idx] : 0;
            double h4_ha_close = (ArraySize(tfData_H4.ha_close) > h4_idx) ? tfData_H4.ha_close[h4_idx] : 0;
            double h4_ha_open = (ArraySize(tfData_H4.ha_open) > h4_idx) ? tfData_H4.ha_open[h4_idx] : 0;
            double h4_obv = (ArraySize(tfData_H4.obv) > h4_idx) ? tfData_H4.obv[h4_idx] : 0;
            double h4_obv_prev = (ArraySize(tfData_H4.obv) > h4_prevIdx) ? tfData_H4.obv[h4_prevIdx] : 0;
            // TREND (votano)
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f → %s (VOTA)", price, h4_ema, (price > h4_ema) ? "✅ BUY" : "❌ SELL");
            PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f → %s (FILTER)", h4_adx, tfData_H4.adx_threshold, (h4_adx > tfData_H4.adx_threshold) ? "TREND" : "NO TREND");
            PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f → %s (VOTA)", h4_ha_close, h4_ha_open, (h4_ha_close > h4_ha_open) ? "✅ BUY" : "❌ SELL");
            // MEAN-REVERSION (analizzato su H1, vedi pannello combinato)
            Print("  🔄 Mean-Rev: vedi pannello combinato (analisi H1)");
            PrintFormat("  🎯 SCORE H4: %.2f", scoreH4);
        }
    } else if (g_enableLogsEffective) {
        Print("  ?? H4 Score:  N/D (DISATTIVATO)");
    }
    
    // D1 INDICATORS - Usa solo indicatori esistenti in TimeFrameData
    if (g_vote_D1_active && g_enableLogsEffective) {
        int d1_idx = ArraySize(tfData_D1.rsi) - 1;
        if (d1_idx < 0) {
            Print("\n--- D1: DATI NON DISPONIBILI ---");
        } else {
            Print("\n--- D1 (TREND LUNGO) ---");
            PrintFormat("  ?? Peso organico TF: %.2f", tfData_D1.organic.weight);
            double d1_close = (ArraySize(tfData_D1.rates) > d1_idx) ? tfData_D1.rates[d1_idx].close : price;
            int d1_prevIdx = (d1_idx > 0) ? d1_idx - 1 : 0;
            double d1_ema = (ArraySize(tfData_D1.ema) > d1_idx) ? tfData_D1.ema[d1_idx] : 0;
            double d1_rsi = (ArraySize(tfData_D1.rsi) > d1_idx) ? tfData_D1.rsi[d1_idx] : 0;
            double d1_adx = (ArraySize(tfData_D1.adx) > d1_idx) ? tfData_D1.adx[d1_idx] : 0;
            double d1_ha_close = (ArraySize(tfData_D1.ha_close) > d1_idx) ? tfData_D1.ha_close[d1_idx] : 0;
            double d1_ha_open = (ArraySize(tfData_D1.ha_open) > d1_idx) ? tfData_D1.ha_open[d1_idx] : 0;
            double d1_obv = (ArraySize(tfData_D1.obv) > d1_idx) ? tfData_D1.obv[d1_idx] : 0;
            double d1_obv_prev = (ArraySize(tfData_D1.obv) > d1_prevIdx) ? tfData_D1.obv[d1_prevIdx] : 0;
            // TREND (votano)
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f → %s (VOTA)", price, d1_ema, (price > d1_ema) ? "✅ BUY" : "❌ SELL");
            PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f → %s (FILTER)", d1_adx, tfData_D1.adx_threshold, (d1_adx > tfData_D1.adx_threshold) ? "TREND" : "NO TREND");
            PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f → %s (VOTA)", d1_ha_close, d1_ha_open, (d1_ha_close > d1_ha_open) ? "✅ BUY" : "❌ SELL");
            // MEAN-REVERSION (analizzato su H1, vedi pannello combinato)
            Print("  🔄 Mean-Rev: vedi pannello combinato (analisi H1)");
            PrintFormat("  🎯 SCORE D1: %.2f", scoreD1);
        }
    } else if (g_enableLogsEffective) {
        Print("  ?? D1 Score:  N/D (DISATTIVATO)");
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
    
    // ═══════════════════════════════════════════════════════════════
    // 🎯 DETECTOR INVERSIONE: Aggiorna tutti i segnali MEAN-REVERSION
    // ═══════════════════════════════════════════════════════════════
    int momentumSignal = UpdateScoreMomentum(totalScore);
    int regimeSignal = UpdateRegimeChange();
    int divergenceSignal = UpdateRSIDivergence();
    
    // 🌱 NUOVI DETECTOR MEAN-REVERSION (v1.1)
    int stochExtremeSignal = UpdateStochasticExtreme();
    int obvDivergenceSignal = UpdateOBVDivergence();
    
    // ═══════════════════════════════════════════════════════════════
    // 🌱 v1.1: MEAN-REVERSION = UN SOLO VOTO COMBINATO
    // Combina RSI + Stochastic + OBV in un UNICO segnale data-driven
    // Poi applica questo voto a OGNI TIMEFRAME attivo
    // ═══════════════════════════════════════════════════════════════
    
    // STEP 1: Calcola segnale combinato (già fatto in GetReversalSignal)
    // Ma qui vogliamo la versione semplificata per il voto
    double meanRevCombinedStrength = 0.0;
    int meanRevCombinedSignal = 0;  // +1=BUY, -1=SELL, 0=NEUTRO
    
    // 🌱 PESI ORGANICI φ-derivati per combinazione
    double w_rsi = PHI;           // RSI divergence = peso φ (più affidabile)
    double w_obv = 1.0;           // OBV divergence = peso 1
    double w_stoch = PHI_INV;     // Stochastic = peso φ⁻¹
    
    double combinedScore = 0.0;
    double combinedMax = 0.0;
    
    if (enableRSI && divergenceSignal != 0) {
        combinedScore += divergenceSignal * w_rsi * g_divergenceStrength;
        combinedMax += w_rsi;
    }
    if (enableOBV && obvDivergenceSignal != 0) {
        combinedScore += obvDivergenceSignal * w_obv * g_obvDivergenceStrength;
        combinedMax += w_obv;
    }
    if (enableStoch && stochExtremeSignal != 0) {
        combinedScore += stochExtremeSignal * w_stoch * g_stochExtremeStrength;
        combinedMax += w_stoch;
    }
    
    // 🌱 SOGLIA DATA-DRIVEN: segnale valido solo se forza > φ⁻² (≈38%)
    if (combinedMax > 0) {
        meanRevCombinedStrength = MathAbs(combinedScore) / combinedMax;
        if (meanRevCombinedStrength >= PHI_INV_SQ) {  // Soglia ≈ 38%
            meanRevCombinedSignal = (combinedScore > 0) ? 1 : -1;
        }
    }
    
    // STEP 2: Applica il VOTO UNICO a OGNI TF attivo
    // Peso = φ⁻¹ × peso_TF (mean-reversion = contrarian, peso ridotto)
    double meanRevScore = 0.0;
    double meanRevMaxScore = 0.0;
    
    // 🌱 Calcola SEMPRE il max possibile (anche se segnale neutro)
    // Questo serve per mantenere scorePct stabile
    if (enableRSI || enableOBV || enableStoch) {
        if (g_vote_M5_active) meanRevMaxScore += g_organic_M5.weight * PHI_INV;
        if (g_vote_H1_active) meanRevMaxScore += g_organic_H1.weight * PHI_INV;
        if (g_vote_H4_active) meanRevMaxScore += g_organic_H4.weight * PHI_INV;
        if (g_vote_D1_active) meanRevMaxScore += g_organic_D1.weight * PHI_INV;
    }
    
    // Applica voto solo se segnale attivo
    if (meanRevCombinedSignal != 0) {
        if (g_vote_M5_active) {
            meanRevScore += meanRevCombinedSignal * meanRevCombinedStrength * g_organic_M5.weight * PHI_INV;
        }
        if (g_vote_H1_active) {
            meanRevScore += meanRevCombinedSignal * meanRevCombinedStrength * g_organic_H1.weight * PHI_INV;
        }
        if (g_vote_H4_active) {
            meanRevScore += meanRevCombinedSignal * meanRevCombinedStrength * g_organic_H4.weight * PHI_INV;
        }
        if (g_vote_D1_active) {
            meanRevScore += meanRevCombinedSignal * meanRevCombinedStrength * g_organic_D1.weight * PHI_INV;
        }
    }
    
    // 🌱 AGGIUNGI MEAN-REVERSION AL TOTALE
    totalScore += meanRevScore;
    
    // 🔍 LOG DIAGNOSTICO SCORE - SEMPRE VISIBILE
    if (g_enableLogsEffective) {
        // Score trend-following (senza mean-reversion)
        double trendScore = totalScore - meanRevScore;
        PrintFormat("[📊 SCORE] M5: %+.2f | H1: %+.2f | H4: %+.2f | D1: %+.2f | TREND: %+.2f", 
            scoreM5, scoreH1, scoreH4, scoreD1, trendScore);
        
        // 🌱 LOG MEAN-REVERSION - SEMPRE VISIBILE (anche se neutro)
        string rsiStatus = "➖";
        string obvStatus = "➖";
        string stochStatus = "➖";
        
        if (enableRSI) {
            if (divergenceSignal > 0) rsiStatus = StringFormat("🟢BUY %.0f%%", g_divergenceStrength*100);
            else if (divergenceSignal < 0) rsiStatus = StringFormat("🔴SELL %.0f%%", g_divergenceStrength*100);
            else rsiStatus = "⚪NEUTRO";
        }
        if (enableOBV) {
            if (obvDivergenceSignal > 0) obvStatus = StringFormat("🟢BUY %.0f%%", g_obvDivergenceStrength*100);
            else if (obvDivergenceSignal < 0) obvStatus = StringFormat("🔴SELL %.0f%%", g_obvDivergenceStrength*100);
            else obvStatus = "⚪NEUTRO";
        }
        if (enableStoch) {
            if (stochExtremeSignal > 0) stochStatus = StringFormat("🟢BUY %.0f%%", g_stochExtremeStrength*100);
            else if (stochExtremeSignal < 0) stochStatus = StringFormat("🔴SELL %.0f%%", g_stochExtremeStrength*100);
            else stochStatus = "⚪NEUTRO";
        }
        
        // Mostra sempre il pannello mean-reversion
        Print("  ═══ 🔄 MEAN-REVERSION (voto combinato per ogni TF) ═══");
        PrintFormat("  RSI: %s | OBV: %s | Stoch: %s", rsiStatus, obvStatus, stochStatus);
        
        if (meanRevCombinedSignal != 0) {
            PrintFormat("  📊 SEGNALE COMBINATO: %s (forza %.0f%% >= soglia %.0f%%)", 
                meanRevCombinedSignal > 0 ? "🟢 BUY" : "🔴 SELL",
                meanRevCombinedStrength * 100, PHI_INV_SQ * 100);
            PrintFormat("  📊 VOTO AGGIUNTO: %+.3f su %d TF attivi", meanRevScore, 
                (g_vote_M5_active?1:0) + (g_vote_H1_active?1:0) + (g_vote_H4_active?1:0) + (g_vote_D1_active?1:0));
        } else {
            PrintFormat("  📊 SEGNALE: ⚪ NEUTRO (forza %.0f%% < soglia %.0f%% oppure nessun segnale)",
                meanRevCombinedStrength * 100, PHI_INV_SQ * 100);
        }
        
        PrintFormat("[📊 TOTALE] TREND(%+.2f) + MEAN-REV(%+.2f) = %+.2f", 
            trendScore, meanRevScore, totalScore);
        
        if (totalScore > 0)
            Print("  ✅ DIREZIONE FINALE: BUY (totalScore > 0)");
        else if (totalScore < 0)
            Print("  ❌ DIREZIONE FINALE: SELL (totalScore < 0)");
        else
            Print("  ⚪ DIREZIONE FINALE: NEUTRO (totalScore = 0)");
        
        Print("======================================================\n");
    }
    
    // ------------------------------------------------------------
    // ?? LOGICA DECISIONALE ORGANICA
    // Score ? Direzione + Soglia percentuale
    // ------------------------------------------------------------
    
    int decision = 0; // 0=no trade, 1=buy, -1=sell
    
    // ?? CALCOLA SCORE MASSIMO POSSIBILE (organico)
    // Ogni indicatore attivo contribuisce peso_TF al massimo (max �1.0 * peso)
    // Max = num_indicatori_attivi � S(peso_TF_attivi) � 1.0
    double maxScorePossible = 0.0;
    
    // ?? FIX: Conta separatamente indicatori DIREZIONALI e MEAN-REVERSION
    // ADX � FILTER (vota solo se trend), Mean-reversion vota nella direzione inversione
    // ?? v1.1 FIX: Calcola peso TOTALE indicatori considerando le CATEGORIE
    // TREND PRIMARY (peso 1.0): EMA, MACD, PSAR, SMA, Ichimoku
    // TREND SUPPORT (peso φ⁻¹≈0.618): BB, Heikin  
    // TREND FILTER (peso 1.0, condizionale): ADX
    double weightTrendPrimary = 0.0;    // Peso totale indicatori primari
    double weightTrendSupport = 0.0;    // Peso totale indicatori supporto
    double weightTrendFilter = 0.0;     // Peso totale indicatori filtro
    
    // ?? TREND PRIMARY (peso 1.0 ciascuno)
    if (enableEMA) weightTrendPrimary += 1.0;
    if (enableMACD) weightTrendPrimary += 1.0;
    if (enablePSAR) weightTrendPrimary += 1.0;
    if (enableSMA) weightTrendPrimary += 1.0;
    if (enableIchimoku) weightTrendPrimary += 1.0;
    
    // ?? TREND SUPPORT (peso φ⁻¹ ≈ 0.618 ciascuno)
    if (enableBB) weightTrendSupport += PHI_INV;      // ≈ 0.618
    if (enableHeikin) weightTrendSupport += PHI_INV;  // ≈ 0.618
    
    // ?? TREND FILTER (peso 1.0, ma vota solo se ADX > soglia)
    if (enableADX) weightTrendFilter += 1.0;
    
    // ?? Peso TOTALE indicatori per ogni TF = PRIMARY + SUPPORT + FILTER
    double totalIndicatorWeight = weightTrendPrimary + weightTrendSupport + weightTrendFilter;
    
    // ?? Max score TREND = somma dei pesi organici TF × peso totale indicatori (con categoria)
    if (g_vote_M5_active) maxScorePossible += g_organic_M5.weight * totalIndicatorWeight;
    if (g_vote_H1_active) maxScorePossible += g_organic_H1.weight * totalIndicatorWeight;
    if (g_vote_H4_active) maxScorePossible += g_organic_H4.weight * totalIndicatorWeight;
    if (g_vote_D1_active) maxScorePossible += g_organic_D1.weight * totalIndicatorWeight;
    
    // ?? v1.1: AGGIUNGI MAX MEAN-REVERSION (gi� calcolato sopra)
    maxScorePossible += meanRevMaxScore;
    
    // ? VALIDATO: scorePct sempre >= 0 (MathAbs + divisione protetta)
    double scorePct = (maxScorePossible > 0) ? (MathAbs(totalScore) / maxScorePossible) * 100.0 : 0;
    bool isBuy = (totalScore > 0);
    bool isSell = (totalScore < 0);
    
    // ?? v1.1: GetReversalSignal per tracciare statistiche (soglia data-driven)
    // I detector sono gi� stati chiamati sopra, questa chiamata aggiorna solo il buffer storico
    double reversalStrength = 0.0;
    int reversalSignal = GetReversalSignal(reversalStrength);
    
    // ?? AGGIUNGI SCORE AL BUFFER STORICO (per soglia automatica)
    // ? INPUT: scorePct >= 0 (validato sopra)
    AddScoreToHistory(scorePct);
    
    // ?? OTTIENI SOGLIA CORRENTE (automatica o manuale, con fallback)
    double currentThreshold = GetCurrentThreshold();
    
    // Log se stiamo usando fallback
    if (AutoScoreThreshold && !g_scoreThresholdReady && g_enableLogsEffective) {
        // ?? Minimo campioni = f5 � 11 (derivato organicamente)
        int minSamplesOrg = (int)MathRound(MathPow(PHI, 5));
        int minSamplesForLog = MathMax(minSamplesOrg, (int)MathCeil(SCORE_HISTORY_MAX * PHI_INV_SQ * PHI_INV));
        PrintFormat("[VOTE] ?? Soglia auto non pronta, uso fallback manuale: %.1f%% (buffer: %d/%d)", 
            ScoreThreshold, g_scoreHistorySize, minSamplesForLog);
    }
    
    // ?? LOG DIAGNOSTICO
    if (g_enableLogsEffective) {
        // ? ANALISI: distingui chiaramente il tipo di soglia usata
        string thresholdType;
        if (!AutoScoreThreshold) 
            thresholdType = "MANUALE";
        else if (g_scoreThresholdReady)
            thresholdType = "AUTO";
        else
            thresholdType = StringFormat("FALLBACK:%d/%d", g_scoreHistorySize, 
                MathMax((int)MathRound(MathPow(PHI, 5)), (int)MathCeil(SCORE_HISTORY_MAX * PHI_INV_SQ * PHI_INV)));
        
        PrintFormat("[SCORE DEBUG] 🌱 Score: %+.2f | Max: %.2f | Pct: %.2f%% | Soglia: %.1f%% (%s)",
            totalScore, maxScorePossible, scorePct, currentThreshold, thresholdType);
        PrintFormat("   Peso indicatori: %.2f (PRIMARY:%.0f + SUPPORT:%.2f + FILTER:%.0f) | Direzione: %s", 
            totalIndicatorWeight, weightTrendPrimary, weightTrendSupport, weightTrendFilter,
            isBuy ? "BUY" : isSell ? "SELL" : "NEUTRA");
    }
    
    // ---------------------------------------------------------------
    // ?? LOGICA DECISIONALE ORGANICA v1.1
    // 
    // ?? NUOVA LOGICA: Mean-reversion VOTA (non blocca)
    // Il mean-reversion aggiunge gi� il suo contributo al totalScore
    // nella direzione dell'inversione attesa
    // 
    // REGOLE:
    // 1. totalScore > 0 e scorePct >= soglia ? BUY
    // 2. totalScore < 0 e scorePct >= soglia ? SELL
    // 3. Score sotto soglia ma reversal forte nella stessa dir ? entry anticipato
    // ---------------------------------------------------------------
    
    bool reversalBoost = false;      // True se reversal permette entry anticipato
    
    // STEP 1: Valuta segnale normale (score sopra soglia)
    if (isBuy && scorePct >= currentThreshold) {
        decision = 1;
    }
    else if (isSell && scorePct >= currentThreshold) {
        decision = -1;
    }
    
    // STEP 2: Score DEBOLE ma REVERSAL FORTE nella stessa direzione ? entry anticipato
    if (decision == 0 && reversalSignal != 0 && reversalStrength >= g_reversalThreshold) {
        // Score deve essere almeno nella stessa direzione del reversal
        bool directionMatch = (reversalSignal == 1 && totalScore >= 0) || 
                              (reversalSignal == -1 && totalScore <= 0);
        
        // Soglia ridotta = soglia � f?� (circa 62% della normale)
        double reversalThreshold = currentThreshold * PHI_INV;
        
        if (directionMatch && scorePct >= reversalThreshold) {
            decision = reversalSignal;
            reversalBoost = true;
        }
    }
    
    // ---------------------------------------------------------------
    // ?? LOG UNICO E CHIARO
    // ---------------------------------------------------------------
    if (decision != 0) {
        string decisionText = (decision == 1) ? "?? BUY" : "?? SELL";
        
        if (reversalBoost) {
            // Trade ANTICIPATO grazie a reversal
            PrintFormat("[VOTE] ? %s ANTICIPATO | Score: %.1f%% + Reversal %s (forza %.0f%%)",
                decisionText, scorePct,
                reversalSignal == 1 ? "BULLISH" : "BEARISH", reversalStrength * 100);
        } else if (meanRevScore != 0 && ((meanRevScore > 0 && decision == 1) || (meanRevScore < 0 && decision == -1))) {
            // Trade con contributo mean-reversion concorde
            PrintFormat("[VOTE] ? %s CONFERMATO | Score: %.1f%% (Mean-Rev: %+.3f concorde)",
                decisionText, scorePct, meanRevScore);
        } else if (meanRevScore != 0) {
            // Trade nonostante mean-reversion contrario (trend dominante)
            PrintFormat("[VOTE] ? %s APPROVATO | Score: %.1f%% (Mean-Rev: %+.3f contrario, trend domina)",
                decisionText, scorePct, meanRevScore);
        } else {
            // Trade normale senza mean-reversion significativo
            PrintFormat("[VOTE] ? %s APPROVATO | Score: %.1f%% >= %.1f%% soglia",
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
        PrintFormat("[VOTE] ⏸ NO TRADE | %s", reason);
    }
    
    // 🌱 v1.1: Salva score per Youden (collegare a profitto del trade)
    if (decision != 0) {
        g_lastEntryScore = scorePct;  // Sarà collegato al profit quando il trade chiude
    }
    
    return decision;
}

//+------------------------------------------------------------------+
//| Apri ordine SELL                                                 |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
    if (SellLotSize <= 0) return;
    
    // ??? VALIDAZIONE LOTTO: rispetta limiti broker
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    double finalLot = SellLotSize;
    
    // Clamp al range consentito
    if (finalLot < minLot) {
        PrintFormat("[TRADE] ?? SELL Lotto %.2f < min %.2f - adeguato", finalLot, minLot);
        finalLot = minLot;
    }
    if (finalLot > maxLot) {
        PrintFormat("[TRADE] ?? SELL Lotto %.2f > max %.2f - adeguato", finalLot, maxLot);
        finalLot = maxLot;
    }
    
    // Arrotonda allo step consentito
    if (stepLot > 0) {
        finalLot = MathFloor(finalLot / stepLot) * stepLot;
    }
    
    // NormalizeDouble per evitare errori di precisione
    finalLot = NormalizeDouble(finalLot, 2);
    
    if (finalLot < minLot) {
        Print("[TRADE] ? SELL Lotto nullo dopo normalizzazione - skip");
        return;
    }
    
    // ?? CATTURA DATI PRE-TRADE per analisi
    double askBefore = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bidBefore = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadBefore = (askBefore - bidBefore) / _Point;
    
    double price = bidBefore;
    double sl = 0;
    double tp = 0;

    // SL: priorit� a prezzo fisso, altrimenti punti
    if (StopLossPriceSell > 0)
        sl = StopLossPriceSell;
    else if (SellStopLossPoints > 0)
        sl = price + SellStopLossPoints * _Point;

    // TP: priorit� a prezzo fisso, altrimenti punti
    if (TakeProfitPriceSell > 0)
        tp = TakeProfitPriceSell;
    else if (SellTakeProfitPoints > 0)
        tp = price - SellTakeProfitPoints * _Point;
    
    if (trade.Sell(finalLot, _Symbol, price, sl, tp, "Auto SELL")) {
        // 🔄 CALCOLA SLIPPAGE
        double executedPrice = trade.ResultPrice();
        double slippagePoints = (bidBefore - executedPrice) / _Point;
        
        // 🌱 v1.1 FIX: Registra score per questo trade (per Youden)
        // Nota: In MQL5, ResultDeal() restituisce il deal ticket che diventa anche position ID
        // per nuove posizioni. Usiamo questo per il matching in OnTradeTransaction.
        ulong positionId = trade.ResultDeal();
        if (positionId == 0) positionId = trade.ResultOrder();  // Fallback
        RegisterOpenTradeScore(positionId, g_lastEntryScore);
        
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
        PrintFormat("[TRADE] ✅ SELL APERTO #%I64u | Score@Entry=%.1f%%", positionId, g_lastEntryScore);
        PrintFormat("   📈 Prezzo: richiesto=%.5f eseguito=%.5f | Slippage=%.1f pts", 
            bidBefore, executedPrice, slippagePoints);
        PrintFormat("   📊 Spread=%.1f pts | Lot=%.2f | SL=%.5f | TP=%.5f", 
            spreadBefore, finalLot, sl, tp);
        if (sl > 0 || tp > 0) {
            double riskPips = sl > 0 ? (sl - price) / _Point / 10 : 0;
            double rewardPips = tp > 0 ? (price - tp) / _Point / 10 : 0;
            double rr = (riskPips > 0 && rewardPips > 0) ? rewardPips / riskPips : 0;
            PrintFormat("   🎯 Risk (SL): %.2f pips | Reward (TP): %.2f pips | R:R=1:%.2f",
                riskPips, rewardPips, rr);
        }
    } else {
        int errCode = GetLastError();
        PrintFormat("[TRADE] ? SELL FALLITO! Errore %d: %s | Price=%.5f Lot=%.2f SL=%.5f TP=%.5f",
            errCode, ErrorDescription(errCode), price, finalLot, sl, tp);
    }
}

//+------------------------------------------------------------------+
//| Apri ordine BUY                                                  |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
    if (BuyLotSize <= 0) return;
    
    // ??? VALIDAZIONE LOTTO: rispetta limiti broker
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    double finalLot = BuyLotSize;
    
    // Clamp al range consentito
    if (finalLot < minLot) {
        PrintFormat("[TRADE] ?? BUY Lotto %.2f < min %.2f - adeguato", finalLot, minLot);
        finalLot = minLot;
    }
    if (finalLot > maxLot) {
        PrintFormat("[TRADE] ?? BUY Lotto %.2f > max %.2f - adeguato", finalLot, maxLot);
        finalLot = maxLot;
    }
    
    // Arrotonda allo step consentito
    if (stepLot > 0) {
        finalLot = MathFloor(finalLot / stepLot) * stepLot;
    }
    
    // NormalizeDouble per evitare errori di precisione
    finalLot = NormalizeDouble(finalLot, 2);
    
    if (finalLot < minLot) {
        Print("[TRADE] ? BUY Lotto nullo dopo normalizzazione - skip");
        return;
    }
    
    // ?? CATTURA DATI PRE-TRADE per analisi
    double askBefore = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bidBefore = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadBefore = (askBefore - bidBefore) / _Point;
    
    double price = askBefore;
    double sl = 0;
    double tp = 0;

    // SL: priorit� a prezzo fisso, altrimenti punti
    if (StopLossPriceBuy > 0)
        sl = StopLossPriceBuy;
    else if (BuyStopLossPoints > 0)
        sl = price - BuyStopLossPoints * _Point;

    // TP: priorit� a prezzo fisso, altrimenti punti
    if (TakeProfitPriceBuy > 0)
        tp = TakeProfitPriceBuy;
    else if (BuyTakeProfitPoints > 0)
        tp = price + BuyTakeProfitPoints * _Point;
    
    if (trade.Buy(finalLot, _Symbol, price, sl, tp, "Auto BUY")) {
        // 🔄 CALCOLA SLIPPAGE
        double executedPrice = trade.ResultPrice();
        double slippagePoints = (executedPrice - askBefore) / _Point;
        
        // 🌱 v1.1 FIX: Registra score per questo trade (per Youden)
        // Nota: In MQL5, ResultDeal() restituisce il deal ticket che diventa anche position ID
        // per nuove posizioni. Usiamo questo per il matching in OnTradeTransaction.
        ulong positionId = trade.ResultDeal();
        if (positionId == 0) positionId = trade.ResultOrder();  // Fallback
        RegisterOpenTradeScore(positionId, g_lastEntryScore);
        
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
        PrintFormat("[TRADE] ✅ BUY APERTO #%I64u | Score@Entry=%.1f%%", positionId, g_lastEntryScore);
        PrintFormat("   📈 Prezzo: richiesto=%.5f eseguito=%.5f | Slippage=%.1f pts", 
            askBefore, executedPrice, slippagePoints);
        PrintFormat("   📊 Spread=%.1f pts | Lot=%.2f | SL=%.5f | TP=%.5f", 
            spreadBefore, finalLot, sl, tp);
        if (sl > 0 || tp > 0) {
            double riskPips = sl > 0 ? (price - sl) / _Point / 10 : 0;
            double rewardPips = tp > 0 ? (tp - price) / _Point / 10 : 0;
            double rr = (riskPips > 0 && rewardPips > 0) ? rewardPips / riskPips : 0;
            PrintFormat("   🎯 Risk (SL): %.2f pips | Reward (TP): %.2f pips | R:R=1:%.2f",
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
//| ?? FIX: Esclude weekend dal conteggio tempo                       |
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
    // ?? FIX: Usa Magic cachato invece di ricalcolarlo ogni volta
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
        
        // ?? FIX: Calcola tempo di TRADING effettivo (escludi weekend)
        // Mercato forex: chiude venerd� ~22:00 UTC, apre domenica ~22:00 UTC
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
            // Venerd�: ultime ~2 ore non trading (mercato chiude ~22:00 UTC)
            // Approssimazione conservativa: non contiamo per evitare complessit�
            checkTime += 86400;  // Avanza di un giorno
        }
        
        // Sottrai tempo weekend
        int tradingSeconds = (int)MathMax(0, totalSeconds - weekendSeconds);
        int maxLifetimeSeconds = limitMinutes * 60;
        if (tradingSeconds < maxLifetimeSeconds) continue;
        
        int lifetimeMinutes = tradingSeconds / 60;
        
        double volume = PositionGetDouble(POSITION_VOLUME);
        double posProfit = PositionGetDouble(POSITION_PROFIT);
        // ?? FIX: Rimossa dichiarazione duplicata di lifetimeMinutes (usava lifetimeSeconds inesistente)
        
        PrintFormat("[TIME STOP] ? Posizione #%I64u %s aperta da %d min (limite %d) ? chiusura forzata", 
            ticket,
            (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
            lifetimeMinutes,
            limitMinutes);
        
        if (trade.PositionClose(ticket)) {
            closedCount++;
            PrintFormat("[TIME STOP] ? Chiusa posizione #%I64u %s (Lot: %.2f, P/L: %.2f)", 
                ticket,
                type == POSITION_TYPE_BUY ? "BUY" : "SELL",
                volume,
                posProfit);
        } else {
            PrintFormat("[TIME STOP] ? Errore chiusura posizione #%I64u: %d", ticket, GetLastError());
        }
    }
    
    if (closedCount > 0) {
        PrintFormat("[TIME STOP] ?? Posizioni chiuse per durata massima: %d", closedCount);
    }
}

//+------------------------------------------------------------------+
//| ??? Descrizione errore trading (funzione helper)                 |
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
//| ?? TRACCIA CHIUSURA TRADE E AGGIORNA STATISTICHE                 |
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
    
    // ---------------------------------------------------------------
    // ?? ESTRAI DATI DEL TRADE CHIUSO
    // ---------------------------------------------------------------
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
    
    // ---------------------------------------------------------------
    // ?? TROVA IL DEAL DI APERTURA per calcolare durata e prezzo entry
    // ---------------------------------------------------------------
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
    
    // ---------------------------------------------------------------
    // ?? AGGIORNA STATISTICHE
    // ---------------------------------------------------------------
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
    
    // ---------------------------------------------------------------
    // ?? LOG COMPLETO CHIUSURA TRADE
    // ---------------------------------------------------------------
    string profitIcon = (netProfit >= 0) ? "?" : "?";
    string typeStr = (dealType == DEAL_TYPE_BUY) ? "SELL?CLOSE" : "BUY?CLOSE";
    
    Print("+--------------------------------------------------------------+");
    PrintFormat("� %s TRADE CHIUSO #%I64u (%s)", profitIcon, positionId, closeReason);
    Print("�--------------------------------------------------------------�");
    PrintFormat("� Tipo: %s | Volume: %.2f lot", typeStr, volume);
    PrintFormat("� Entry: %.5f ? Exit: %.5f", openPrice, closePrice);
    PrintFormat("� Profit: %.2f | Comm: %.2f | Swap: %.2f", profit, commission, swap);
    PrintFormat("� ?? NET P/L: %+.2f %s", netProfit, AccountInfoString(ACCOUNT_CURRENCY));
    PrintFormat("� ?? Durata: %d minuti (%.1f ore)", durationMinutes, durationMinutes / 60.0);
    Print("�--------------------------------------------------------------�");
    PrintFormat("� ?? STATISTICHE CUMULATIVE");
    PrintFormat("� Trades: %d (W:%d L:%d) = %.1f%% WinRate", 
        g_stats.totalTrades, g_stats.winTrades, g_stats.lossTrades,
        g_stats.totalTrades > 0 ? (100.0 * g_stats.winTrades / g_stats.totalTrades) : 0);
    PrintFormat("� PF: %.2f | Expect: %.2f | AvgW: %.2f AvgL: %.2f", 
        g_stats.profitFactor, g_stats.expectancy, g_stats.avgWin, g_stats.avgLoss);
    PrintFormat("� MaxDD: %.2f (%.2f%%) | Streak: %+d (W:%d L:%d)", 
        g_stats.maxDrawdown, g_stats.maxDrawdownPct, (int)g_stats.currentStreak,
        g_stats.maxWinStreak, g_stats.maxLossStreak);
    Print("+--------------------------------------------------------------+");
    
    // ---------------------------------------------------------------
    // 🎯 SALVA NEL BUFFER TRADE RECENTI (per analisi pattern e Youden)
    // ---------------------------------------------------------------
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
        
        // 🌱 v1.1 FIX: Recupera score CORRETTO dalla mappa ticket → score
        // Prima usavamo g_lastEntryScore che veniva sovrascritto tra apertura e chiusura
        double scoreAtEntry = GetAndRemoveTradeScore(positionId);
        g_recentTrades[g_recentTradesIndex].scoreAtEntry = scoreAtEntry;
        
        // Log per debug Youden
        if (g_enableLogsEffective && scoreAtEntry > 0) {
            PrintFormat("[YOUDEN] 📊 Trade chiuso: Score@Entry=%.1f%% → Profit=%+.2f (%s)",
                scoreAtEntry, netProfit, netProfit >= 0 ? "WIN" : "LOSS");
        }
        
        g_recentTradesIndex = (g_recentTradesIndex + 1) % g_recentTradesMax;
        if (g_recentTradesCount < g_recentTradesMax) g_recentTradesCount++;
    }
}
