//+------------------------------------------------------------------+
//| --------------------------------------------------------------- |
// SISTEMA 100% ORGANICO  - TUTTO DERIVATO DAI DATI                  |
//| --------------------------------------------------------------- |
//|                                                                 |
//| SCALE DINAMICHE BASATE SU HURST (2^H):                          |
//|   - NESSUNA costante a priori - tutto dai DATI                  |
//|   - Scale = 2^H dove H = Esponente di Hurst empirico            |
//|   - H=0.5 -> 2^0.5 ~ 1.414 (random walk)                        |
//|   - H=0.7 -> 2^0.7 ~ 1.625 (trending)                           |
//|   - H=0.3 -> 2^0.3 ~ 1.231 (mean-reverting)                     |
//|                                                                 |
//| FORMULA PERIODI (100% data-driven):                             |
//|   naturalPeriod = autocorrelazione dei DATI (no minuti!)        |
//|   scale = 2^H (derivato dall'Esponente di Hurst)                |
//|   decay = 2^(-H) = 1/scale                                      |
//|   periodi_indicatori = naturalPeriod x potenze di scale         |
//|                                                                 |
//| FORMULA PESI TF (Esponente di Hurst):                           |
//|   peso_TF = H_TF / Sum(H_tutti_TF)                              |
//|   H > centro: trending -> peso maggiore                         |
//|   H derivato con metodo R/S (Rescaled Range)                    |
//|                                                                 |
//| CENTRI ADATTIVI - SOGLIE 100% DATA-DRIVEN (non 0.55/0.45 fissi!):|
//|   center = media(H osservati), margin = stdev(H) x decay(H)     |
//|   TRENDING (H > center+margin):     EMA (recency bias)          |
//|   RANDOM (centermargin):           Mediana (robusto)           |
//|   REVERTING (H < center-margin):    Trimmed Mean (oscillazione) |
//|   Transizioni: blend lineare per evitare discontinuita          |
//|                                                                 |
//| SOGLIE DINAMICHE:                                               |
//|   ADX threshold = avg + decay x stddev (dai dati)               |
//|   Score threshold = OTSU->YOUDEN (100% data-driven)             |
//|   Zona Hurst = centro +/- stdev x decay (dai dati)              |
//|                                                                 |
//| READY CHECK:                                                    |
//|   L'EA NON entra a mercato finche non ha abbastanza dati        |
//|   per calcolare TUTTI i valori organici (no fallback!)          |
//|                                                                 |
//| --------------------------------------------------------------- |
//| VALIDAZIONI IMPLEMENTATE:                                       |
//| --------------------------------------------------------------- |
//| 1. HURST EXPONENT: Range [0.1, 0.9] forzato in output           |
//| 2. DIVISIONI: Tutte protette contro /0 con check denominatore   |
//| 3. BUFFER CIRCOLARI: Indici sempre in [0, MAX-1] via modulo     |
//| 4. SOMME INCREMENTALI: Sanity check per floating point errors   |
//| 5. VARIANZA: Protezione sqrt(negativo) -> ritorna 0.0           |
//| 6. SCORE THRESHOLD: Bounds P25 <-> P75 della distribuzione      |
//| 7. CONFIDENCE: Output sempre in [0.0, 1.0]                      |
//| 8. REGIME HURST: Sempre ritorna ENUM valida (default=RANDOM)    |
//| --------------------------------------------------------------- |
//+------------------------------------------------------------------+
#property copyright "Pietro Giacobazzi, Juri Corradi, Alessandro Brehas"
#property version   "5.00"
#property description "EA Jarvis - SISTEMA 100% DATA-DRIVEN (Scale 2^H)"

#include <Trade\Trade.mqh>
#include <Arrays\ArrayDouble.mqh>

// +---------------------------------------------------------------------------+
//                      MONEY MANAGEMENT & GENERALE
// +---------------------------------------------------------------------------+
input group "--- GENERALE ---"
input bool   enableTrading        = true;       // Abilita trading (false = solo analisi)
input int    MaxOpenTrades        = 500;        // Massimo posizioni aperte
input double MaxSpread            = 35;         // Spread massimo in punti
input uint   MaxSlippage          = 40;         // Slippage max in punti
input int    MagicNumber          = 123456;     // Magic Number (base, viene modificato per simbolo)

//+------------------------------------------------------------------+
//| FIX: Calcola Magic Number unico per simbolo                      |
//| Evita conflitti quando EA gira su piu' simboli contemporaneamente|
//| FIX: Usa ulong per evitare overflow integer durante hash         |
//+------------------------------------------------------------------+
int CalculateUniqueMagicNumber()
{
    // FIX: Usa ulong per evitare overflow durante moltiplicazione
    ulong symbolHash = 0;
    string sym = _Symbol;
    
    // Numero primo grande per modulo (evita overflow mantenendo distribuzione)
    const ulong PRIME_MOD = 2147483647;  // Piu' grande primo che sta in int32
    
    for (int i = 0; i < StringLen(sym); i++) {
        // Modulo dopo ogni operazione per evitare overflow
        symbolHash = ((symbolHash * 31) % PRIME_MOD + StringGetCharacter(sym, i)) % PRIME_MOD;
    }
    
    // Limita a range ragionevole per evitare collisioni con altri EA
    int hashOffset = (int)(symbolHash % 100000);
    
    // FIX: Protezione overflow - se MagicNumber + hashOffset supera INT_MAX
    int maxSafeOffset = INT_MAX - MagicNumber;
    if (maxSafeOffset < 0) {
        // MagicNumber gia' troppo grande, usa offset 0
        PrintFormat("[MAGIC] MagicNumber %d troppo grande, hashOffset azzerato", MagicNumber);
        hashOffset = 0;
    } else if (hashOffset > maxSafeOffset) {
        // Riduci hashOffset per evitare overflow
        hashOffset = hashOffset % (maxSafeOffset + 1);
    }
    
    // Combina con MagicNumber base
    return MagicNumber + hashOffset;
}

// FIX: Cache Magic Number (calcolato 1x in OnInit, riutilizzato ovunque)
int g_uniqueMagicNumber = 0;

// +---------------------------------------------------------------------------+
//                          PARAMETRI BUY                                   
// +---------------------------------------------------------------------------+
input group "--- ORDINI BUY ---"
input double BuyLotSize           = 0.1;       // Lotto fisso per ordini BUY
input int    BuyStopLossPoints    = 0;          // SL BUY in punti (0=disattivato)
input int    BuyTakeProfitPoints  = 500;        // TP BUY in punti (0=disattivato)
input double StopLossPriceBuy     = 0.0;        // SL BUY prezzo fisso (priorit su punti)
input double TakeProfitPriceBuy   = 0.0;        // TP BUY prezzo fisso (priorit su punti)
input int    BuyTimeStopMinutes   = 7200;       // Stop loss temporale BUY (0=disattivato)
input int    BuyTrailingStartPoints = 200;      // BUY Trailing: attiva dopo X punti profitto (0=disattivato)
input int    BuyTrailingStepPoints  = 100;      // BUY Trailing: mantieni SL a Y punti dal prezzo corrente

// +---------------------------------------------------------------------------+
//                           PARAMETRI SELL                                 
// +---------------------------------------------------------------------------+
input group "--- ORDINI SELL ---"
input double SellLotSize          = 0.1;        // Lotto fisso per ordini SELL
input int    SellStopLossPoints   = 0;          // SL SELL in punti (0=disattivato)
input int    SellTakeProfitPoints = 500;        // TP SELL in punti (0=disattivato)
input double StopLossPriceSell    = 0.0;        // SL SELL prezzo fisso (priorit su punti)
input double TakeProfitPriceSell  = 0.0;        // TP SELL prezzo fisso (priorit su punti)
input int    SellTimeStopMinutes  = 7200;       // Stop loss temporale SELL (0=disattivato)
input int    SellTrailingStartPoints = 200;     // SELL Trailing: attiva dopo X punti profitto (0=disattivato)
input int    SellTrailingStepPoints  = 100;     // SELL Trailing: mantieni SL a Y punti dal prezzo corrente

// +---------------------------------------------------------------------------+
//                      TIMEFRAME & SISTEMA VOTO                            
// +---------------------------------------------------------------------------+
input group "---TIMEFRAME ---"
input bool   EnableIndicatorVoteSystem = true;  // Abilita sistema voti/pesi indicatori
input bool   EnableVote_M5             = true;  // Usa timeframe M5 nel voto
input bool   EnableVote_H1             = true;  // Usa timeframe H1 nel voto
input bool   EnableVote_H4             = true;  // Usa timeframe H4 nel voto
input bool   EnableVote_D1             = true;  // Usa timeframe D1 nel voto

// +---------------------------------------------------------------------------+
//                            LOG & DEBUG
// +---------------------------------------------------------------------------+
input group "--- LOG ---"
input bool   EnableLogs                = true;  // Abilita TUTTI i log (true=completi, false=silenzioso)
input bool   ExportTradesCSV           = true;  // Esporta trade in CSV per Monte Carlo
input bool   ExportExtendedTradesCSV   = true;  // Esporta CSV esteso con contesto (score/soglie/Hurst/spread/slippage/closeReason)

// +---------------------------------------------------------------------------+
//                           CIRCUIT BREAKER
// +---------------------------------------------------------------------------+
// Letter C: due breaker separati
// 1) Operational: errori tecnici in finestra temporale
// 2) Performance: troppe loss consecutive / winrate bassa su ultimi N trade
// Nota: blocca SOLO nuove entry. Uscite, trailing e gestione posizioni restano attive.
input group "--- CIRCUIT BREAKER ---"
input bool   EnableCircuitBreaker              = true;   // Master switch
input bool   EnableOperationalBreaker          = true;   // Blocca su errori operativi
input int    OpErrorWindowSeconds              = 600;    // Finestra errori (sec)
input int    OpMaxErrorsInWindow               = 5;      // Soglia errori per blocco
input int    OpCooldownSeconds                 = 1800;   // Cooldown dopo trigger (sec)
input bool   EnablePerformanceBreaker          = true;   // Blocca su performance scarsa
input int    PerfLookbackTrades                = 10;     // Finestra ultimi N trade chiusi
input int    PerfMaxConsecutiveLosses          = 3;      // Loss consecutive per trigger
input double PerfMinWinRatePct                 = 35.0;   // Se winrate < soglia e net<0 => trigger
input int    PerfCooldownSeconds               = 7200;   // Cooldown dopo trigger (sec)

// ---------------------------------------------------------------------------
// SISTEMA 100% ORGANICO - Nessun valore hardcodato
// ---------------------------------------------------------------------------
// FORMULA PERIODI: naturalPeriod = autocorrelazione dei DATI
// Tutti i periodi derivano dal naturalPeriod usando rapporti f
//
// FORMULA PESI (ESPONENTE DI HURST - Metodo R/S):
// peso_TF = hurstExponent_TF / somma(hurstExponent_tutti_TF)
// H > g_hurstCenter: trending -> peso maggiore
// H ~= g_hurstCenter: random -> peso minore (zona no-trade)
// H < g_hurstCenter: mean-reverting -> peso maggiore
// ---------------------------------------------------------------------------

//--- Struttura per contenere i valori organici calcolati per ogni TF
struct OrganicPeriods {
    // PERIODI (derivati da naturalPeriod x potenze di f)
    int ema;           // EMA period
    int rsi;           // RSI period (usato solo per divergenza, non vota)
    int macd_fast;     // MACD fast
    int macd_slow;     // MACD slow
    int macd_signal;   // MACD signal
    int bb;            // Bollinger period
    double bb_dev;     // BB deviation (organica)
    int atr;           // ATR period
    int adx;           // ADX period
    
    // INDICATORI TREND AGGIUNTIVI (da v1.0)
    double psar_step;  // PSAR step organico = decay^4
    double psar_max;   // PSAR max organico = decay
    int sma_fast;      // SMA veloce = naturalPeriod x scale
    int sma_slow;      // SMA lenta = naturalPeriod  scale
    int ichimoku_tenkan;  // Tenkan-sen = naturalPeriod
    int ichimoku_kijun;   // Kijun-sen = naturalPeriod  scale
    int ichimoku_senkou;  // Senkou Span B = naturalPeriod  scale
    
    // INDICATORI MEAN-REVERSION (votano direzione inversione)
    int stoch_k;          // Stochastic %K = naturalPeriod
    int stoch_d;          // Stochastic %D = naturalPeriod  decay
    int stoch_slowing;    // Slowing = round(scale)  2-3
    
    int min_bars_required; // Barre minime necessarie
    
    // PESO TF (calcolato da ESPONENTE DI HURST)
    double weight;           // Peso del timeframe normalizzato
    double hurstExponent;    // Esponente di Hurst (0-1): H>centro=trending, H<centro=mean-reverting
    
    // SCALE DINAMICHE (derivate da Hurst)
    double scale;            // 2^H - fattore di espansione
    double decay;            // 2^(-H) - fattore di contrazione
    
    // PERIODO NATURALE (derivato dall'autocorrelazione dei DATI)
    // Questo  la BASE da cui derivano TUTTE le scale
    int naturalPeriod; // Periodo naturale del mercato per questo TF
};

//--- Periodi organici per ogni timeframe (calcolati in OnInit)
OrganicPeriods g_organic_M5, g_organic_H1, g_organic_H4, g_organic_D1;

//  FIX: Periodi precedenti per rilevare cambi significativi (>25%)
// Se i periodi cambiano drasticamente, gli handle indicatori devono essere ricreati
OrganicPeriods g_prevOrganic_M5, g_prevOrganic_H1, g_prevOrganic_H4, g_prevOrganic_D1;
bool g_periodsInitialized = false;  // Flag: primi periodi calcolati?

//--- Flag per indicare se i dati sono pronti
bool g_dataReady_M5 = false;
bool g_dataReady_H1 = false;
bool g_dataReady_H4 = false;
bool g_dataReady_D1 = false;

// +---------------------------------------------------------------------------+
//               INDICATORI TECNICI (tutti organici)
// ---------------------------------------------------------------------------
// I pesi sono calcolati con ESPONENTE DI HURST:
//   peso_TF = hurstExponent_TF / S(hurstExponent)
//   H > g_hurstCenter -> peso maggiore (trending)
//   H ~= g_hurstCenter -> peso minore (random, zona no-trade)
// +---------------------------------------------------------------------------+

// ---------------------------------------------------------------------------
// INDICATORI TREND-FOLLOWING (filosofia coerente: seguire il trend)
// TREND PRIMARIO: EMA, MACD, PSAR, SMA Cross, Ichimoku
// TREND FILTER: ADX (forza trend)
// TREND SUPPORT: Heikin Ashi (noise reduction), OBV (conferma volume)
// RSI: usato per rilevare divergenze (non vota inversione)
// ---------------------------------------------------------------------------
input group "--- INDICATORI TREND PRIMARIO ---"
input bool   enableEMA       = true;    // EMA (trend direction)
input bool   enableMACD      = true;    // MACD (trend momentum)
input bool   enablePSAR      = true;    // Parabolic SAR (trend reversal points)
input bool   enableSMA       = true;    // SMA Cross (trend confirmation)
input bool   enableIchimoku  = true;    // Ichimoku (multi-trend system)

input group "--- INDICATORI TREND FILTER ---"
input bool   enableADX       = true;    // ADX (trend strength - vota solo se > soglia)

input group "--- INDICATORI TREND SUPPORT ---"
input bool   enableHeikin    = true;    // Heikin Ashi (noise reduction, trend confirm)
input bool   enableBB        = true;    // Bollinger Bands (volatility filter)

input group "--- INDICATORI MEAN-REVERSION (votano direzione inversione) ---"
input bool   enableRSI       = true;    // RSI: oversold->BUY, overbought->SELL (soglia f)
input bool   enableStoch     = true;    // Stochastic: zone estreme -> voto inversione
input bool   enableOBV       = true;    // OBV: divergenze volume/prezzo -> voto inversione

// +---------------------------------------------------------------------------+
// |              SISTEMA ORGANICO (Hurst & Soglie)                             |
// +---------------------------------------------------------------------------+
// | FILTRO HURST: Blocca trade quando H in centro storico (zona random)       |
// | SOGLIA SCORE: Automatica = mean + stdev * decay dai dati storici          |
// | MEAN-REVERSION: RSI/Stoch/OBV votano nella direzione dell'inversione      |
// +---------------------------------------------------------------------------+
input group "--- SISTEMA ORGANICO ---"
input bool   EnableHurstFilter  = true;         // Abilita filtro no-trade zone (H in zona random)
input bool   EnableHurstSoftMode = true;        // Se true: NON blocca hard le entry, ma alza la soglia richiesta quando TradeScore Hurst e' debole
input double HurstSoftMaxPenaltyPct = 50.0;     // Max penalita' soglia in modalita' soft (es: 50 = soglia * 1.50 nel worst case)
input int    HurstSoftSummaryEveryBars = 100;   // Log riepilogo soft Hurst ogni N barre (0=off). Non sostituisce i log DECISION.

input bool   EnableTFCoherenceFilter = false;    // Se true: valida coerenza regime Hurst tra TF (evita conflitti M5 vs H4/D1)
input bool   TFCoherenceHardBlock = false;       // Se true: blocca entry se conflitto forte; se false: penalizza soglia (soft)
input double TFCoherencePenaltyPct = 30.0;       // Penalita' max (soft): aumenta soglia effettiva in caso di conflitto (es: 30 = x1.30)
input bool   AutoScoreThreshold = true;         // Soglia automatica (true) o manuale (false)
input double ScoreThreshold     = 50.0;         // Soglia manuale (50% = mediana) - solo se Auto=false

input group "--- PERFORMANCE BACKTEST ---"
input int    RecalcEveryBars    = 0;            // Ricalcolo ogni N barre (0=ogni barra, 100=veloce, 200=molto veloce)

// -------------------------------------------------------------------------------
//  SISTEMA SCALE DINAMICHE 2^H - 100% DATA-DRIVEN
// -------------------------------------------------------------------------------
// NESSUNA costante matematica a priori - tutto derivato da 2^H!
// Le scale sono DERIVATE dall'Esponente di Hurst del mercato stesso.
//
// FORMULA SCALE:
//   scale(H) = 2^H     dove H = Esponente di Hurst empirico
//   decay(H) = 2^(-H)  = 1/scale(H)
//
// PROPRIET:
//   H = 0.5 (random walk)    scale = 2  1.414, decay  0.707
//   H = 0.6 (leggero trend)  scale  1.516, decay  0.660
//   H = 0.7 (trending)       scale  1.625, decay  0.616
//   H = 0.4 (mean-reverting) scale  1.320, decay  0.758
//   H = 0.3 (forte MR)       scale  1.231, decay  0.812
//
// 100% DATA-DRIVEN: scale e decay derivati direttamente da 2^H
// dove H = Esponente di Hurst calcolato empiricamente dai dati
// -------------------------------------------------------------------------------

//  RIMOSSE COSTANTI DEFAULT - Sistema 100% empirico, zero fallback arbitrari
// Tutte le funzioni Get*() usano valori calcolati dai dati o da limiti empirici

//  RANGE HURST - Limiti statistici ragionevoli
// Basati sulla teoria: H < 0.1 o H > 0.9 sono estremamente rari nei mercati reali
const double HURST_RANGE_MIN = 0.1;                       // Minimo teorico (fallback bootstrap)
const double HURST_RANGE_MAX = 0.9;                       // Massimo teorico (fallback bootstrap)

// NOTA: TUTTI I PERCENTILI ORA DERIVANO DA HURST!
// Al posto di costanti statiche (0.25, 0.38, 0.62, 0.75), usiamo:
//   - decay(H) = 2^(-2H)  0.25 per H=0.5 (quartile inferiore)
//   - decay(H) = 2^(-H)  0.62 per H=0.7 (quartile superiore)
//   - 1-decay(H)  0.75 per H=0.5 (complemento del quartile inferiore)
// Questo rende il sistema 100% data-driven dall'esponente di Hurst

//  RIMOSSE COSTANTI DEFAULT_PERIOD - Sistema 100% empirico
// Tutti i periodi naturali calcolati da autocorrelazione dei dati di mercato
// g_naturalPeriod_M5/H1/H4/D1 iniziano a 0 e vengono calcolati in CalculateNaturalPeriod()

//  Hurst medio globale (aggiornato dinamicamente)
// Usato per calcolare scale quando TF non ha ancora H proprio
// DICHIARATO QUI per essere disponibile alle funzioni GetBuffer*()
//  Init bootstrap: centro range teorico (0.1+0.9)/2 = 0.5
double g_hurstGlobal = (HURST_RANGE_MIN + HURST_RANGE_MAX) / 2.0;  // Bootstrap data-driven

//  FUNZIONE: Calcola buffer size data-driven
// Restituisce: periodo  scale^esponente(H)
// USA g_hurstGlobal per adattarsi al regime di mercato corrente!
int GetDataDrivenBufferSize(int basePeriod, double H, int exponent)
{
    //  Usa base EMPIRICA (calcolata da ratios TF) o 2.0 fallback teorico
    double base = GetScaleBase();  // Empirica: ~2.0-2.5 dai dati, non fisso
    double scale = MathPow(base, H);  // base^H
    double size = basePeriod * MathPow(scale, (double)exponent);
    return MathMax(4, (int)MathRound(size));  // Minimo 4 per stabilit statistica
}

//  FUNZIONI BUFFER 100% DATA-DRIVEN
// Prima OnInit: usa BOOTSTRAP_MIN_BARS (minimo statistico)
// Dopo OnInit: usa periodi empirici calcolati dai dati
//  Si adattano dinamicamente a Hurst e periodi naturali!
int GetBufferSmall()   
{ 
    int base = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    return GetDataDrivenBufferSize(base, g_hurstGlobal, 0); 
}

int GetBufferMedium()  
{ 
    int base = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    return GetDataDrivenBufferSize(base, g_hurstGlobal, 1); 
}

int GetBufferLarge()   
{ 
    int base = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : BOOTSTRAP_MIN_BARS;
    return GetDataDrivenBufferSize(base, g_hurstGlobal, 1); 
}

int GetBufferXLarge()  
{ 
    int base = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : BOOTSTRAP_MIN_BARS;
    int result = GetDataDrivenBufferSize(base, g_hurstGlobal, 2);
    return MathMax(result, 128);  // Minimo 128 barre per calcoli robusti
}

int GetBufferHuge()    
{ 
    int base = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : BOOTSTRAP_MIN_BARS;
    int result = GetDataDrivenBufferSize(base, g_hurstGlobal, 3);
    return MathMax(result, 256);  // Minimo 256 barre per Hurst stabile
}
//  DATA-DRIVEN: Limiti empirici aggiornati dinamicamente dai dati osservati
double g_hurstMin_observed = 1.0;                         // Minimo H osservato (inizia a 1.0)
double g_hurstMax_observed = 0.0;                         // Massimo H osservato (inizia a 0.0)
int    g_hurstObservations = 0;                           // Numero osservazioni per validazione
const int HURST_MIN_OBSERVATIONS = 10;                    // Minimo osservazioni prima di usare limiti empirici

//  BOOTSTRAP: Costanti minime statistiche per inizializzazione
const int BOOTSTRAP_MIN_BARS = 64;                        // Minimo robusto per analisi statistiche (era 8, troppo basso)
// BOOTSTRAP_SAFE_BARS calcolato dinamicamente in OnInit come g_naturalPeriod_Min  2

//  DATA-DRIVEN: Periodi naturali empirici (da autocorrelazione)
int g_naturalPeriod_M5 = 0;                               // Periodo naturale M5
int g_naturalPeriod_H1 = 0;                               // Periodo naturale H1
int g_naturalPeriod_H4 = 0;                               // Periodo naturale H4
int g_naturalPeriod_D1 = 0;                               // Periodo naturale D1
int g_naturalPeriod_Min = 0;                              // Minimo tra tutti i periodi attivi

//  LOOKBACK ADATTIVO: numero di barre per calcolare periodo naturale (auto-organizzante)
// Il lookback emerge dal periodo naturale stesso: lookback = periodo  scale(H)  
// Bootstrap iniziale: BOOTSTRAP_MIN_BARS  4-8 (dipende da H)
int g_lookback_M5 = 0;                                    // Lookback adattivo M5
int g_lookback_H1 = 0;                                    // Lookback adattivo H1
int g_lookback_H4 = 0;                                    // Lookback adattivo H4
int g_lookback_D1 = 0;                                    // Lookback adattivo D1

//  DATA-DRIVEN: Base di scala empirica (derivata dal rapporto TF)
double g_empiricalScaleBase = 2.0;                        // Base di scala (default 2, poi calcolato dai dati)
bool   g_scaleBaseReady = false;                          // True quando calcolato empiricamente

// (g_hurstGlobal gi dichiarato sopra alle funzioni GetBuffer*)

// ---------------------------------------------------------------------------
//  OTTIMIZZAZIONE PERFORMANCE BACKTEST
// ---------------------------------------------------------------------------
int    g_barsSinceLastRecalc = 0;           // Contatore barre dall'ultimo ricalcolo
bool   g_isBacktest = false;                 // Flag: siamo in backtest?
bool   g_enableLogsEffective = true;         // Log effettivi (auto-disabilitati in backtest)

// ---------------------------------------------------------------------------
//  DIAGNOSTICA SOFT HURST (OPTION 1)
//  Usata per log chiari in ExecuteTradingLogic(). Aggiornata in ExecuteVotingLogic().
// ---------------------------------------------------------------------------
double g_lastHurstSoftMult = 1.0;
double g_lastThresholdBasePct = 0.0;
double g_lastThresholdEffPct = 0.0;
double g_lastScorePct = 0.0;
bool   g_lastHurstSoftActive = false;
bool   g_lastHurstSoftSuppressed = false;
int    g_lastDominantDirection = 0; // +1 BUY, -1 SELL, 0 NEUTRO (utile per log quando soft-hurst sopprime un'entry)

// Coerenza multi-timeframe (regimi Hurst): diagnostica ultimo giro
double g_lastTFCoherenceMult = 1.0;
bool   g_lastTFCoherenceActive = false;
bool   g_lastTFCoherenceBlocked = false;
int    g_lastTFCoherenceConflictCount = 0;
int    g_lastTFCoherenceSupportCount = 0;

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

int RegimeToInt(ENUM_HURST_REGIME r)
{
    if (r == HURST_TRENDING) return 1;
    if (r == HURST_MEANREV) return -1;
    return 0;
}

bool IsRegimeOpposite(ENUM_HURST_REGIME a, ENUM_HURST_REGIME b)
{
    int ia = RegimeToInt(a);
    int ib = RegimeToInt(b);
    return (ia != 0 && ib != 0 && ia == -ib);
}

// Ritorna true se entry consentita dalla coerenza, e fornisce un moltiplicatore soglia (>=1)
bool GetTFCoherenceDecision(int decisionDir, double &outMult, int &outConflicts, int &outSupports)
{
    outMult = 1.0;
    outConflicts = 0;
    outSupports = 0;

    if (!EnableTFCoherenceFilter) return true;
    if (decisionDir == 0) return true;

    // Coerenza = i TF maggiori non devono essere in regime opposto a quelli minori.
    // Semplificazione robusta: controlliamo coppie (M5 vs H4/D1) e (H1 vs H4/D1) se attivi.
    bool haveM5 = g_vote_M5_active;
    bool haveH1 = g_vote_H1_active;
    bool haveH4 = g_vote_H4_active;
    bool haveD1 = g_vote_D1_active;

    if (haveM5 && haveH4) {
        if (IsRegimeOpposite(g_hurstRegime_M5, g_hurstRegime_H4)) outConflicts++; else outSupports++;
    }
    if (haveM5 && haveD1) {
        if (IsRegimeOpposite(g_hurstRegime_M5, g_hurstRegime_D1)) outConflicts++; else outSupports++;
    }
    if (haveH1 && haveH4) {
        if (IsRegimeOpposite(g_hurstRegime_H1, g_hurstRegime_H4)) outConflicts++; else outSupports++;
    }
    if (haveH1 && haveD1) {
        if (IsRegimeOpposite(g_hurstRegime_H1, g_hurstRegime_D1)) outConflicts++; else outSupports++;
    }

    // Se abbiamo pochi TF attivi, la coerenza ha poco senso
    if ((outConflicts + outSupports) == 0) return true;

    // Score conflitto in [0..1]
    double conflictRatio = (double)outConflicts / (double)(outConflicts + outSupports);

    if (TFCoherenceHardBlock) {
        // Blocca solo se conflitto pieno (tutte le coppie considerate sono opposte)
        // -> evita blocchi "a sorpresa" quando c'e' solo un TF random.
        if (outConflicts > 0 && outSupports == 0) {
            return false;
        }
        return true;
    }

    // Soft: penalizza soglia in modo proporzionale al conflitto
    double maxPenaltyPct = MathMax(0.0, TFCoherencePenaltyPct);
    if (maxPenaltyPct > 300.0) maxPenaltyPct = 300.0;
    double maxMult = 1.0 + (maxPenaltyPct / 100.0);
    outMult = 1.0 + conflictRatio * (maxMult - 1.0);
    if (outMult < 1.0) outMult = 1.0;
    return true;
}

//  PERIODI EMPIRICI CALCOLATI DAI DATI (usati dopo OnInit)
int    g_empiricalPeriod_M5 = 0;             // Periodo naturale M5 (da autocorrelazione)
int    g_empiricalPeriod_H1 = 0;             // Periodo naturale H1 (da autocorrelazione)
int    g_empiricalPeriod_H4 = 0;             // Periodo naturale H4 (da autocorrelazione)
int    g_empiricalPeriod_D1 = 0;             // Periodo naturale D1 (da autocorrelazione)
int    g_empiricalPeriod_Min = 0;            // Minimo tra tutti i periodi attivi (base sistema)

//  CACHE FLAGS (le variabili struct sono dichiarate dopo NaturalPeriodResult)
bool   g_cacheValid = false;                 // Cache valida?
int    g_hurstRecalcCounter = 0;             // Contatore per ricalcolo Hurst
bool   g_tfDataCacheValid = false;           // Cache dati TF valida?
int    g_tfDataRecalcCounter = 0;            // Contatore per reload dati TF

//  FIX: Variabili per rilevamento gap di prezzo e invalidazione cache
double g_lastCachePrice = 0.0;               // Ultimo prezzo quando cache valida
double g_lastCacheATR = 0.0;                 // Ultimo ATR quando cache valida

//  FIX: Warmup period - evita trading prima di stabilizzazione indicatori
datetime g_eaStartTime = 0;                  // Timestamp avvio EA
bool   g_warmupComplete = false;             // Flag: warmup completato?
int    g_warmupBarsRequired = 0;             // Barre minime prima di tradare (calcolato in OnInit)

// ---------------------------------------------------------------------------
//  NOTA: Ora TUTTO  derivato da:
// 1. PERIODO NATURALE = autocorrelazione dei DATI (CalculateNaturalPeriodForTF)
// 2. SCALE DINAMICHE = 2^H dove H = Esponente di Hurst empirico
// 3. DECAY DINAMICO = 2^(-H) = 1/scale
//
// Riferimento scale per vari H:
// H=0.3  scale=1.23, decay=0.81 | H=0.4  scale=1.32, decay=0.76
// H=0.5  scale=1.41, decay=0.71 | H=0.6  scale=1.52, decay=0.66
// H=0.7  scale=1.62, decay=0.62 | H=0.8  scale=1.74, decay=0.57
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
//  SISTEMA PURO - NESSUN FALLBACK
// Se non abbiamo abbastanza dati per calcolare i centri empirici,
// il timeframe viene DISABILITATO (isDataReady = false) e loggato l'errore.
// Questo garantisce che OGNI decisione sia basata su dati REALI.
// ---------------------------------------------------------------------------

//  Struttura per ritornare periodo naturale E esponente di Hurst
struct NaturalPeriodResult {
    int period;              // Periodo naturale (lag dove autocorr < decay)
    double hurstExponent;    // Esponente di Hurst (0-1): confrontato con g_hurstCenter
    bool valid;              // true se calcolo OK, false se dati insufficienti
};

//  CACHE PER RISULTATI HURST (dichiarata dopo la struct)
NaturalPeriodResult g_cachedResult_M5, g_cachedResult_H1, g_cachedResult_H4, g_cachedResult_D1;

//  RICALCOLO PERIODI NATURALI (ad ogni nuova barra H4)
datetime g_lastH4BarTime = 0;              // Ultima barra H4 processata per periodi naturali

//--- Oggetti trading e indicatori
CTrade          trade;
datetime        lastBarTime = 0;
datetime        lastHurstRecalc = 0;  //  Ultimo ricalcolo Hurst

//+------------------------------------------------------------------+
//| Circuit Breaker (Letter C)                                      |
//| Blocca SOLO nuove entry. Gestione posizioni resta attiva.        |
//+------------------------------------------------------------------+
datetime g_cbBlockUntilOp = 0;
datetime g_cbBlockUntilPerf = 0;

datetime g_cbOpErrorTimes[];

double g_cbPerfPnL[];
int    g_cbPerfWin[];          // 1=win, 0=loss
int    g_cbPerfIndex = 0;
int    g_cbPerfCount = 0;
int    g_cbPerfConsecutiveLosses = 0;

datetime g_cbLastLogTime = 0;
bool     g_cbWasBlocked = false;
datetime g_cbLastOpUntil = 0;
datetime g_cbLastPerfUntil = 0;

void CB_Reset()
{
    g_cbBlockUntilOp = 0;
    g_cbBlockUntilPerf = 0;
    ArrayResize(g_cbOpErrorTimes, 0);

    int n = MathMax(1, PerfLookbackTrades);
    ArrayResize(g_cbPerfPnL, n);
    ArrayResize(g_cbPerfWin, n);
    ArrayInitialize(g_cbPerfPnL, 0.0);
    ArrayInitialize(g_cbPerfWin, 0);
    g_cbPerfIndex = 0;
    g_cbPerfCount = 0;
    g_cbPerfConsecutiveLosses = 0;
    g_cbLastLogTime = 0;
}

void CB_Init()
{
    // Reset sempre per evitare stati sporchi tra run
    CB_Reset();
    if (!EnableCircuitBreaker) return;

    if (EnableLogs) {
        PrintFormat("[CB] Init: Op=%s (win=%ds max=%d cd=%ds) | Perf=%s (N=%d streak=%d WR<%.1f cd=%ds)",
            EnableOperationalBreaker ? "ON" : "OFF",
            OpErrorWindowSeconds, OpMaxErrorsInWindow, OpCooldownSeconds,
            EnablePerformanceBreaker ? "ON" : "OFF",
            MathMax(1, PerfLookbackTrades), PerfMaxConsecutiveLosses, PerfMinWinRatePct, PerfCooldownSeconds);
    }
}

// ---------------------------------------------------------------------------
// EXPORT ESTESO (non superficiale)
// NOTE: Definizioni posizionate PRIMA degli helper per compatibilita' compilatore.
// ---------------------------------------------------------------------------
struct EntrySnapshot {
    ulong   positionId;
    datetime openTime;
    int     direction;            // +1 BUY, -1 SELL
    double  volume;
    double  requestedPrice;
    double  executedPrice;
    double  sl;
    double  tp;
    double  spreadPtsAtOpen;
    double  slippagePtsAtOpen;

    double  scorePctAtEntry;
    double  thresholdBasePct;
    double  thresholdEffPct;
    int     thresholdMethodId;    // 0=MANUAL, 1=AUTO_WARMUP, 2=OTSU, 3=YOUDEN
    double  hurstSoftMult;
    double  tfCoherenceMult;
    int     tfCoherenceConflicts;
    int     tfCoherenceSupports;
    int     tfCoherenceBlocked;   // 1/0

    double  hurstTradeScore;
    double  hurstTradeThreshold;
    int     hurstReady;           // 1/0
    int     hurstAllowTrade;      // 1/0
    double  hurstGlobal;
    double  hurstComposite;
    double  hurstCenter;
    double  hurstStdev;
    int     regimeM5;
    int     regimeH1;
    int     regimeH4;
    int     regimeD1;
};

struct ExtendedTradeRecord {
    ulong   positionId;
    datetime openTime;
    datetime closeTime;
    int     direction;            // +1 BUY, -1 SELL
    string  symbol;
    double  volume;
    double  requestedOpenPrice;
    double  executedOpenPrice;
    double  openPrice;
    double  closePrice;
    double  commission;
    double  swap;
    double  profit;
    double  netProfit;
    double  balanceAfter;
    int     durationMinutes;
    long    magic;
    string  comment;
    string  closeReason;

    // Entry context
    double  spreadPtsAtOpen;
    double  slippagePtsAtOpen;
    double  sl;
    double  tp;

    double  scorePctAtEntry;
    double  thresholdBasePct;
    double  thresholdEffPct;
    int     thresholdMethodId;
    double  hurstSoftMult;
    double  tfCoherenceMult;
    int     tfCoherenceConflicts;
    int     tfCoherenceSupports;
    int     tfCoherenceBlocked;

    double  hurstTradeScore;
    double  hurstTradeThreshold;
    int     hurstReady;
    int     hurstAllowTrade;
    double  hurstGlobal;
    double  hurstComposite;
    double  hurstCenter;
    double  hurstStdev;
    int     regimeM5;
    int     regimeH1;
    int     regimeH4;
    int     regimeD1;
};

EntrySnapshot g_openEntrySnaps[];
int g_openEntrySnapsCount = 0;
int g_openEntrySnapsCap = 0;

ExtendedTradeRecord g_extendedTrades[];
int g_extendedTradesCount = 0;
int g_extendedTradesCap = 0;

double g_extExportStartBalance = 0.0;  // calcolato in export come in ExportTradesToCSV
double g_extExportRunningBalance = 0.0;

//+------------------------------------------------------------------+
//| EXPORT ESTESO: helpers snapshot / buffer                        |
//+------------------------------------------------------------------+
bool NearlyEqual(double a, double b, double eps)
{
    return (MathAbs(a - b) <= eps);
}

bool IsDuplicateExtendedTrade(const ExtendedTradeRecord &rec)
{
    // Safety: scan solo una finestra recente (duplicati tipicamente adiacenti)
    int n = g_extendedTradesCount;
    int start = MathMax(0, n - 200);
    for (int i = n - 1; i >= start; i--) {
        if (g_extendedTrades[i].positionId != rec.positionId) continue;
        if (g_extendedTrades[i].closeTime != rec.closeTime) continue;

        // Confronti con tolleranza per evitare issue float
        if (!NearlyEqual(g_extendedTrades[i].netProfit, rec.netProfit, 0.0001)) continue;
        if (!NearlyEqual(g_extendedTrades[i].volume, rec.volume, 0.0000001)) continue;
        if (!NearlyEqual(g_extendedTrades[i].closePrice, rec.closePrice, _Point * 0.5)) continue;

        return true;
    }
    return false;
}

bool IsPositionOpenById(ulong positionId)
{
    if (positionId == 0) return false;
    int total = PositionsTotal();
    for (int i = total - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (!PositionSelectByTicket(ticket)) continue;
        long ident = PositionGetInteger(POSITION_IDENTIFIER);
        if (ident > 0 && (ulong)ident == positionId) return true;
    }
    return false;
}

int FindOpenEntrySnapIndex(ulong positionId)
{
    int n = g_openEntrySnapsCount;
    for (int i = 0; i < n; i++) {
        if (g_openEntrySnaps[i].positionId == positionId) return i;
    }
    return -1;
}

bool GetEntrySnapshot(ulong positionId, EntrySnapshot &outSnap)
{
    int idx = FindOpenEntrySnapIndex(positionId);
    if (idx < 0) return false;
    outSnap = g_openEntrySnaps[idx];
    return true;
}

void EnsureOpenEntrySnapsCapacity(int minCap)
{
    if (g_openEntrySnapsCap >= minCap) return;
    int newCap = (g_openEntrySnapsCap <= 0) ? 16 : g_openEntrySnapsCap;
    while (newCap < minCap) newCap *= 2;
    ArrayResize(g_openEntrySnaps, newCap);
    g_openEntrySnapsCap = newCap;
}

void RegisterEntrySnapshot(const EntrySnapshot &snap)
{
    if (snap.positionId == 0) return;

    // Safety: in teoria le posizioni aperte simultanee sono limitate, ma evitiamo crescita anomala
    const int OPEN_SNAP_MAX = 5000;
    if (g_openEntrySnapsCount >= OPEN_SNAP_MAX) {
        static bool s_loggedSnapMax = false;
        if (!s_loggedSnapMax) {
            PrintFormat("[EXPORT-EXT] Troppi snapshot aperti (%d). Stop register per safety.", OPEN_SNAP_MAX);
            s_loggedSnapMax = true;
        }
        return;
    }

    int idx = FindOpenEntrySnapIndex(snap.positionId);
    if (idx >= 0) {
        g_openEntrySnaps[idx] = snap;
        return;
    }
    EnsureOpenEntrySnapsCapacity(g_openEntrySnapsCount + 1);
    g_openEntrySnaps[g_openEntrySnapsCount] = snap;
    g_openEntrySnapsCount++;
}

bool GetAndRemoveEntrySnapshot(ulong positionId, EntrySnapshot &outSnap)
{
    int idx = FindOpenEntrySnapIndex(positionId);
    if (idx < 0) return false;
    outSnap = g_openEntrySnaps[idx];
    // remove by swap-last
    int last = g_openEntrySnapsCount - 1;
    if (last >= 0 && idx != last) {
        g_openEntrySnaps[idx] = g_openEntrySnaps[last];
    }
    g_openEntrySnapsCount = MathMax(0, g_openEntrySnapsCount - 1);
    // non ridimensioniamo array per evitare churn
    return true;
}

void EnsureExtendedTradesCapacity(int minCap)
{
    if (g_extendedTradesCap >= minCap) return;
    int newCap = (g_extendedTradesCap <= 0) ? 256 : g_extendedTradesCap;
    while (newCap < minCap) newCap *= 2;
    ArrayResize(g_extendedTrades, newCap);
    g_extendedTradesCap = newCap;
}

void AppendExtendedTrade(const ExtendedTradeRecord &rec)
{
    // Anti-duplicati: evita doppie righe identiche (es. eventi ripetuti)
    if (IsDuplicateExtendedTrade(rec)) {
        static int s_dupLogCount = 0;
        if (EnableLogs && s_dupLogCount < 5) {
            PrintFormat("[EXPORT-EXT] Duplicate suppressed #%I64u @ %s",
                rec.positionId, TimeToString(rec.closeTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS));
            s_dupLogCount++;
        }
        return;
    }

    // Safety: evita crescita memoria illimitata in run lunghi/rumorosi
    const int EXTENDED_EXPORT_MAX_RECORDS = 200000;
    if (g_extendedTradesCount >= EXTENDED_EXPORT_MAX_RECORDS) {
        static bool s_loggedMax = false;
        if (!s_loggedMax) {
            PrintFormat("[EXPORT-EXT] Buffer pieno (%d record). Stop append per safety.", EXTENDED_EXPORT_MAX_RECORDS);
            s_loggedMax = true;
        }
        return;
    }

    EnsureExtendedTradesCapacity(g_extendedTradesCount + 1);
    g_extendedTrades[g_extendedTradesCount] = rec;
    g_extendedTradesCount++;
}

string RegimeToStringInt(int r)
{
    if (r > 0) return "TREND";
    if (r < 0) return "REVERT";
    return "RANDOM";
}


void CB_GetOperationalSnapshot(datetime now, int &errorsInWindow, int &windowSec, int &remainingSec)
{
    errorsInWindow = 0;
    windowSec = MathMax(1, OpErrorWindowSeconds);
    remainingSec = 0;

    if (!EnableCircuitBreaker || !EnableOperationalBreaker) return;

    CB_PurgeOperationalErrors(now);
    errorsInWindow = ArraySize(g_cbOpErrorTimes);
    if (now < g_cbBlockUntilOp) remainingSec = (int)(g_cbBlockUntilOp - now);
}

void CB_GetPerformanceSnapshot(int &count, int &wins, double &net, double &winRatePct, int &lossStreak, int &remainingSec)
{
    count = g_cbPerfCount;
    wins = 0;
    net = 0.0;
    winRatePct = 0.0;
    lossStreak = g_cbPerfConsecutiveLosses;
    remainingSec = 0;

    if (!EnableCircuitBreaker || !EnablePerformanceBreaker) return;

    int n = MathMax(1, PerfLookbackTrades);
    if (g_cbPerfCount > 0) {
        int maxIter = MathMin(g_cbPerfCount, n);
        for (int i = 0; i < maxIter; i++) {
            wins += g_cbPerfWin[i];
            net += g_cbPerfPnL[i];
        }
        // Se buffer pieno, usiamo N esatto
        int denom = (g_cbPerfCount >= n) ? n : g_cbPerfCount;
        winRatePct = (denom > 0) ? (100.0 * (double)wins / (double)denom) : 0.0;
    }

    datetime now = TimeCurrent();
    if (now < g_cbBlockUntilPerf) remainingSec = (int)(g_cbBlockUntilPerf - now);
}

void CB_LogUnblockTransitions()
{
    if (!EnableCircuitBreaker || !EnableLogs) return;

    datetime now = TimeCurrent();
    bool blockedNow = false;
    if (EnableOperationalBreaker && now < g_cbBlockUntilOp) blockedNow = true;
    if (EnablePerformanceBreaker && now < g_cbBlockUntilPerf) blockedNow = true;

    // Log solo quando passiamo da bloccato -> sbloccato
    if (g_cbWasBlocked && !blockedNow) {
        Print("[CB] UNBLOCK: nuove entry riabilitate");
    }
    g_cbWasBlocked = blockedNow;

    // Aggiorna cache per debug (utile se vuoi stampare fino-a quando)
    g_cbLastOpUntil = g_cbBlockUntilOp;
    g_cbLastPerfUntil = g_cbBlockUntilPerf;
}

bool CB_AllowNewEntries(string &reasonOut, int &secondsRemaining)
{
    reasonOut = "";
    secondsRemaining = 0;
    if (!EnableCircuitBreaker) return true;

    datetime now = TimeCurrent();
    int remOp = (EnableOperationalBreaker && now < g_cbBlockUntilOp) ? (int)(g_cbBlockUntilOp - now) : 0;
    int remPerf = (EnablePerformanceBreaker && now < g_cbBlockUntilPerf) ? (int)(g_cbBlockUntilPerf - now) : 0;

    if (remOp <= 0 && remPerf <= 0) return true;

    if (remOp >= remPerf) {
        reasonOut = "OPERATIONAL";
        secondsRemaining = remOp;
    } else {
        reasonOut = "PERFORMANCE";
        secondsRemaining = remPerf;
    }
    return false;
}

void CB_PurgeOperationalErrors(datetime now)
{
    int windowSec = MathMax(1, OpErrorWindowSeconds);
    int n = ArraySize(g_cbOpErrorTimes);
    while (n > 0) {
        if ((now - g_cbOpErrorTimes[0]) <= windowSec) break;
        ArrayRemove(g_cbOpErrorTimes, 0);
        n = ArraySize(g_cbOpErrorTimes);
    }
}

void CB_RecordOperationalError(const string reason, int errCode, datetime eventTime = 0)
{
    if (!EnableCircuitBreaker || !EnableOperationalBreaker) return;
    if (OpMaxErrorsInWindow <= 0) return;

    datetime t = (eventTime > 0) ? eventTime : TimeCurrent();
    CB_PurgeOperationalErrors(t);

    int n = ArraySize(g_cbOpErrorTimes);
    ArrayResize(g_cbOpErrorTimes, n + 1);
    g_cbOpErrorTimes[n] = t;

    int count = ArraySize(g_cbOpErrorTimes);
    if (count >= OpMaxErrorsInWindow) {
        int cd = MathMax(0, OpCooldownSeconds);
        g_cbBlockUntilOp = t + cd;
        ArrayResize(g_cbOpErrorTimes, 0);
        PrintFormat("[CB OP] TRIGGER: %d errori in %ds. Cooldown=%ds | reason=%s err=%d",
            OpMaxErrorsInWindow, MathMax(1, OpErrorWindowSeconds), cd, reason, errCode);
    } else {
        // Log soft, throttled
        if (EnableLogs && (g_cbLastLogTime == 0 || (t - g_cbLastLogTime) >= 60)) {
            PrintFormat("[CB OP] error %d/%d in %ds | reason=%s err=%d",
                count, OpMaxErrorsInWindow, MathMax(1, OpErrorWindowSeconds), reason, errCode);
            g_cbLastLogTime = t;
        }
    }
}

void CB_RecordClosedTrade(double netProfit, datetime closeTime)
{
    if (!EnableCircuitBreaker || !EnablePerformanceBreaker) return;
    datetime t = (closeTime > 0) ? closeTime : TimeCurrent();

    int n = MathMax(1, PerfLookbackTrades);
    if (ArraySize(g_cbPerfPnL) != n) {
        ArrayResize(g_cbPerfPnL, n);
        ArrayResize(g_cbPerfWin, n);
        ArrayInitialize(g_cbPerfPnL, 0.0);
        ArrayInitialize(g_cbPerfWin, 0);
        g_cbPerfIndex = 0;
        g_cbPerfCount = 0;
        g_cbPerfConsecutiveLosses = 0;
    }

    bool isWin = (netProfit >= 0.0);
    if (!isWin) g_cbPerfConsecutiveLosses++; else g_cbPerfConsecutiveLosses = 0;

    g_cbPerfPnL[g_cbPerfIndex] = netProfit;
    g_cbPerfWin[g_cbPerfIndex] = isWin ? 1 : 0;
    g_cbPerfIndex = (g_cbPerfIndex + 1) % n;
    if (g_cbPerfCount < n) g_cbPerfCount++;

    bool trigger = false;
    string triggerReason = "";

    if (PerfMaxConsecutiveLosses > 0 && g_cbPerfConsecutiveLosses >= PerfMaxConsecutiveLosses) {
        trigger = true;
        triggerReason = StringFormat("LOSS_STREAK_%d", g_cbPerfConsecutiveLosses);
    } else if (g_cbPerfCount >= n) {
        int wins = 0;
        double net = 0.0;
        for (int i = 0; i < n; i++) {
            wins += g_cbPerfWin[i];
            net += g_cbPerfPnL[i];
        }
        double winRate = 100.0 * (double)wins / (double)n;
        if (winRate < PerfMinWinRatePct && net < 0.0) {
            trigger = true;
            triggerReason = StringFormat("WR_%.1f_NET_%.2f", winRate, net);
        }
    }

    if (trigger) {
        int cd = MathMax(0, PerfCooldownSeconds);
        g_cbBlockUntilPerf = t + cd;
        PrintFormat("[CB PERF] TRIGGER: %s | Cooldown=%ds (blocca nuove entry)", triggerReason, cd);

        // Reset per evitare retrigger immediato
        ArrayInitialize(g_cbPerfPnL, 0.0);
        ArrayInitialize(g_cbPerfWin, 0);
        g_cbPerfIndex = 0;
        g_cbPerfCount = 0;
        g_cbPerfConsecutiveLosses = 0;
    }
}

//+------------------------------------------------------------------+
//|  FUNZIONI HELPER: SCALE DINAMICHE                               |
//| Base di scala: 2^H (default) o empirica dai rapporti TF          |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|  DATA-DRIVEN: Calcola base empirica da rapporti timeframe      |
//| Analizza rapporto tra periodi naturali di TF consecutivi         |
//+------------------------------------------------------------------+
void CalculateEmpiricalScaleBase()
{
    // Serve almeno 2 TF con periodi validi
    int validCount = 0;
    double ratioSum = 0.0;
    
    // Rapporto M5  H1 (teorico: 12x = 60min / 5min)
    if (g_naturalPeriod_M5 > 0 && g_naturalPeriod_H1 > 0) {
        double ratio = (double)g_naturalPeriod_H1 / (double)g_naturalPeriod_M5;
        ratioSum += ratio;
        validCount++;
    }
    
    // Rapporto H1  H4 (teorico: 4x)
    if (g_naturalPeriod_H1 > 0 && g_naturalPeriod_H4 > 0) {
        double ratio = (double)g_naturalPeriod_H4 / (double)g_naturalPeriod_H1;
        ratioSum += ratio;
        validCount++;
    }
    
    // Rapporto H4  D1 (teorico: 6x)
    if (g_naturalPeriod_H4 > 0 && g_naturalPeriod_D1 > 0) {
        double ratio = (double)g_naturalPeriod_D1 / (double)g_naturalPeriod_H4;
        ratioSum += ratio;
        validCount++;
    }
    
    // Serve almeno 1 rapporto valido
    if (validCount > 0) {
        double avgRatio = ratioSum / validCount;
        // Base empirica = radice del rapporto medio
        // Se ratio  4, base  2 (2^1 = 2, 2^2 = 4)
        g_empiricalScaleBase = MathPow(avgRatio, 1.0 / (validCount + 1.0));
        g_scaleBaseReady = true;
        
        if (g_enableLogsEffective) {
                    PrintFormat("[SCALE] Base empirica calcolata: %.3f (da %d rapporti TF, ratio medio: %.2f)", 
                g_empiricalScaleBase, validCount, avgRatio);
        }
    }
}

//+------------------------------------------------------------------+
//| Ottieni base di scala (empirica o default)                       |
//+------------------------------------------------------------------+
double GetScaleBase()
{
    return g_scaleBaseReady ? g_empiricalScaleBase : 2.0;
}

//+------------------------------------------------------------------+
//| Clamp H without recursion                                        |
//| Uses observed bounds if available, otherwise theoretical range   |
//+------------------------------------------------------------------+
double ClampHurstObservedOrTheoretical(double h)
{
    double minH = HURST_RANGE_MIN;
    double maxH = HURST_RANGE_MAX;
    if (g_hurstObservations >= HURST_MIN_OBSERVATIONS) {
        minH = MathMax(0.01, g_hurstMin_observed);
        maxH = MathMin(0.99, g_hurstMax_observed);
    }
    return MathMax(minH, MathMin(maxH, h));
}

//+------------------------------------------------------------------+
//| Ottieni BOOTSTRAP_SAFE_BARS dinamico (g_naturalPeriod_Min  2)  |
//+------------------------------------------------------------------+
int GetBootstrapSafeBars()
{
    // Se periodi naturali disponibili, usa minimo  2
    if (g_naturalPeriod_Min > 0) return g_naturalPeriod_Min * 2;
    // Altrimenti fallback a BOOTSTRAP_MIN_BARS  scale(Hdefault)
    double scaleBase = GetScaleBase();  // Empirico o 2.0 teorico
    double H = GetDefaultHurst();       // Empirico o 0.5 teorico
    double scale2 = MathPow(scaleBase, H * 2.0);  // scale(H)
    return (int)MathRound(BOOTSTRAP_MIN_BARS * scale2);  // ~8  2.83  23 per H=0.5
}

//+------------------------------------------------------------------+
//|  DATA-DRIVEN: Ottieni H di default (empirico o teorico)       |
//| Usa g_hurstCenter se disponibile, altrimenti 0.5 teorico        |
//+------------------------------------------------------------------+
double GetDefaultHurst()
{
    // Se centro empirico disponibile (calcolato dai dati)
    if (g_hurstCenter > 0.01 && g_hurstCenter < 0.99) {
        return g_hurstCenter;  // Media empirica osservata
    }
    //  Fallback teorico: centro range (min+max)/2 - derivato da limiti
    return (HURST_RANGE_MIN + HURST_RANGE_MAX) / 2.0;  // Centro teorico
}

// Calcola il fattore di scala dal Hurst exponent
// scale(H) = base^H dove base  empirica (o 2 di default)
// H = 0.5, base=2  2  1.414 (random walk)
// H = 0.7, base=2  2^0.7  1.625 (trending)
double GetOrganicScale(double H)
{
    // Clamp H al range valido senza ricorsione
    double h = ClampHurstObservedOrTheoretical(H);
    double base = GetScaleBase();  // Empirica o 2.0
    return MathPow(base, h);
}

// Calcola il fattore di decadimento dal Hurst exponent  
// decay(H) = base^(-H) = 1/scale(H) dove base  empirica
// H = 0.5, base=2  1/2  0.707 (random walk)
// H = 0.7, base=2  2^(-0.7)  0.616 (trending)
double GetOrganicDecay(double H)
{
    // Clamp H al range valido senza ricorsione
    double h = ClampHurstObservedOrTheoretical(H);
    double base = GetScaleBase();  // Empirica o 2.0
    return MathPow(base, -h);
}

// Calcola potenza n-esima della scala
// scale^n(H) = base^(n*H)
// Utile per: scale = base^(2H), scale = base^(3H), etc.
double GetOrganicScalePow(double H, double n)
{
    double h = ClampHurstObservedOrTheoretical(H);
    double base = GetScaleBase();  // Empirica o 2.0
    return MathPow(base, n * h);
}

//+------------------------------------------------------------------+
//|  DATA-DRIVEN: Ottieni limiti Hurst empirici (min/max osservati) |
//| Fallback a limiti teorici se dati insufficienti                  |
//+------------------------------------------------------------------+
double GetHurstMin()
{
    // Se abbastanza osservazioni, usa minimo empirico + margine sicurezza
    if (g_hurstObservations >= HURST_MIN_OBSERVATIONS) {
        // Margine derivato da decay(H) calcolato DIRETTAMENTE per evitare ricorsione
        // decay(H) = base^(-2H)
        double base = GetScaleBase();
        double h0 = ClampHurstObservedOrTheoretical(GetDefaultHurst());
        double margin = MathPow(base, -2.0 * h0);
        return MathMax(0.01, g_hurstMin_observed - margin);  // Non sotto 0.01 (limite fisico)
    }
    return HURST_RANGE_MIN;  // Fallback teorico
}

double GetHurstMax()
{
    // Se abbastanza osservazioni, usa massimo empirico + margine sicurezza
    if (g_hurstObservations >= HURST_MIN_OBSERVATIONS) {
        // Margine derivato da decay(H) calcolato DIRETTAMENTE per evitare ricorsione
        // decay(H) = base^(-2H)
        double base = GetScaleBase();
        double h0 = ClampHurstObservedOrTheoretical(GetDefaultHurst());
        double margin = MathPow(base, -2.0 * h0);
        return MathMin(0.99, g_hurstMax_observed + margin);  // Non oltre 0.99 (limite fisico)
    }
    return HURST_RANGE_MAX;  // Fallback teorico
}

//+------------------------------------------------------------------+
//|  DATA-DRIVEN: Aggiorna limiti empirici con nuovo valore H       |
//+------------------------------------------------------------------+
void UpdateHurstLimits(double newHurst)
{
    // Filtra outlier estremi (es. errori calcolo)
    if (newHurst < 0.01 || newHurst > 0.99) return;
    
    g_hurstMin_observed = MathMin(g_hurstMin_observed, newHurst);
    g_hurstMax_observed = MathMax(g_hurstMax_observed, newHurst);
    g_hurstObservations++;
    
    // Log primo aggiornamento significativo
    if (g_hurstObservations == HURST_MIN_OBSERVATIONS && g_enableLogsEffective) {
        PrintFormat("[HURST] Limiti empirici attivati: [%.3f, %.3f] (da %d osservazioni)", 
            GetHurstMin(), GetHurstMax(), g_hurstObservations);
    }
}

//+------------------------------------------------------------------+
//|  SLIDING WINDOW: Cleanup buffer quando vicino al limite       |
//| Elimina 30% pi vecchio per evitare crash memoria                |
//+------------------------------------------------------------------+
void CleanupHistoryBuffer(double &buffer[], int &size, int &index, double &sum, double &sumSq)
{
    //  CIRCULAR BUFFER PURO: non ridimensiona, solo sovrascrive
    // Evita stack overflow e loop infiniti di cleanup
    int maxSize = ArraySize(buffer);
    if (maxSize <= 0) return;
    
    // Buffer circolare: l'indice avanza automaticamente e sovrascrive i vecchi
    // Non serve fare nulla qui - la sovrascrittura avviene nel chiamante
    // Questa funzione ora  un no-op per sicurezza
    return;
}

// Calcola potenza n-esima del decay
// decay^n(H) = base^(-n*H)
// Utile per: decay = base^(-2H), decay = base^(-3H), etc.
double GetOrganicDecayPow(double H, double n)
{
    // Clamp H al range valido senza ricorsione
    double h = ClampHurstObservedOrTheoretical(H);
    double base = GetScaleBase();  // Empirica o 2.0
    return MathPow(base, -n * h);
}

// Aggiorna l'Hurst globale come media ponderata di tutti i TF attivi
void UpdateGlobalHurst()
{
    double sumH = 0.0;
    int count = 0;
    
    if (g_dataReady_M5 && g_organic_M5.hurstExponent > 0) {
        sumH += g_organic_M5.hurstExponent;
        count++;
    }
    if (g_dataReady_H1 && g_organic_H1.hurstExponent > 0) {
        sumH += g_organic_H1.hurstExponent;
        count++;
    }
    if (g_dataReady_H4 && g_organic_H4.hurstExponent > 0) {
        sumH += g_organic_H4.hurstExponent;
        count++;
    }
    if (g_dataReady_D1 && g_organic_D1.hurstExponent > 0) {
        sumH += g_organic_D1.hurstExponent;
        count++;
    }
    
    if (count > 0) {
        double oldHurst = g_hurstGlobal;
        g_hurstGlobal = sumH / count;
        
        //  CHECK RESIZE DINAMICO: verifica se Hurst  cambiato significativamente
        // Soglia = 1(H) invece di 2 per triggare resize pi frequente (met confidenza)
        double minThreshold = GetOrganicDecayPow(GetDefaultHurst(), 2.0);  // decay(H) empirico
        double resizeThreshold = MathMax(minThreshold, g_hurstStdev);  // Fallback empirico se stdev non pronta
        if (MathAbs(g_hurstGlobal - oldHurst) > resizeThreshold) {
            CheckAndResizeBuffers();
        }
    }
    // Altrimenti mantiene il valore precedente o GetDefaultHurst()
}

// ---------------------------------------------------------------------------
//  FILTRO HURST NO-TRADE ZONE - 100% DATA-DRIVEN
// ---------------------------------------------------------------------------
// Se il mercato  in regime "random" (H  centro storico), i segnali sono rumore.
// 
// SOGLIE 100% DAI DATI STORICI:
//   g_hurstZoneMargin = stdev(H)  decay (derivato da H stesso!)
//   g_hurstRandomLow = centro - margine
//   g_hurstRandomHigh = centro + margine
//
// REGIME (basato su soglie data-driven):
//   H > g_hurstRandomHigh: TRENDING  trade permessi
//   H < g_hurstRandomLow: MEAN-REVERTING  trade permessi  
//   g_hurstRandomLow < H < g_hurstRandomHigh: RANDOM  NO TRADE
//
// VOTING: tradeScore = |H - centro|  confidence, confrontato con soglia dinamica
// ---------------------------------------------------------------------------

//  SOGLIE ZONA RANDOM 100% DATA-DRIVEN
// TUTTO derivato dai dati storici del cross:
//   g_hurstCenter = media(H) storica
//   g_hurstZoneMargin = stdev(H)  decay (data-driven!)
//   zona_random = [g_hurstRandomLow, g_hurstRandomHigh]
double g_hurstCenter = 0.0;                                   // Centro DINAMICO = media(H) storica
double g_hurstZoneMargin = 0.0;                               // Margine = stdev(H) * decay(H)
double g_hurstRandomLow = 0.0;                                // centro - margine
double g_hurstRandomHigh = 0.0;                               // centro + margine
bool   g_hurstZoneReady = false;                              // True quando calcolato da dati

// Buffer storico per valori H (per calcolare stdev adattiva)
double g_hurstHistory[];                                      // Buffer H storici
int g_hurstHistorySize = 0;                                   // Numero H memorizzati
int g_hurstHistoryIndex = 0;                                  // Indice corrente (buffer circolare)
// Dimensione buffer: potenza di 2 (calcolata dinamicamente)
int HURST_HISTORY_MAX = 0;                                    // Calcolato in OnInit
double g_hurstStdev = 0.0;                                    // Stdev storica di H

// SOMME INCREMENTALI per Hurst (O(1) invece di O(n))
double g_hurstSum = 0.0;                                      // S(H) per calcolo media
double g_hurstSumSq = 0.0;                                    // S(H^2) per calcolo varianza
int    g_hurstOperationCount = 0;                             // FIX: Contatore operazioni per ricalcolo periodico anti-drift

// Buffer storico per tradeScore (per soglia data-driven del filtro Hurst)
double g_tradeScoreHistory[];
int    g_tradeScoreHistorySize = 0;
int    g_tradeScoreHistoryIndex = 0;
// Dimensione buffer: potenza di 2 (calcolata dinamicamente)
int TRADE_SCORE_HISTORY_MAX = 0;                              // Calcolato in OnInit
double g_tradeScoreThreshold = 0.0;                           // Soglia data-driven del tradeScore
bool   g_tradeScoreReady = false;                             // True quando soglia calcolata dai dati

// SOMME INCREMENTALI per TradeScore (O(1) invece di O(n))
double g_tradeScoreSum = 0.0;                                 // S(tradeScore)
double g_tradeScoreSumSq = 0.0;                               // S(tradeScore^2)
int    g_tradeScoreOperationCount = 0;                        // FIX: Contatore operazioni per ricalcolo periodico anti-drift

// ---------------------------------------------------------------------------
// STATISTICHE TRADING PER ANALISI PROFITTO
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
    double scoreAtEntry;       //  v1.1: Score % al momento dell'apertura (per Youden)
    string closeReason;        // "SL", "TP", "TIME_STOP", "SIGNAL"
};

TradeRecord g_recentTrades[];
int g_recentTradesMax = 0;     // Calcolato in OnInit come round(f8)  47
int g_recentTradesCount = 0;
int g_recentTradesIndex = 0;

// ---------------------------------------------------------------------------
// EXPORT ESTESO (non superficiale)
// (Struct + buffer dichiarati sopra, prima degli helper, per compatibilita')
// ---------------------------------------------------------------------------

string ThresholdMethodToString(int id)
{
    switch (id) {
        case 0:  return "MANUAL";
        case 1:  return "AUTO_WARMUP";
        case 2:  return "OTSU";
        case 3:  return "YOUDEN";
        default: return "UNKNOWN";
    }
}

void ExportExtendedTradesToCSV()
{
    if (!ExportExtendedTradesCSV) return;

    if (g_extendedTradesCount <= 0) {
        Print("[EXPORT-EXT] Nessun trade esteso da esportare (buffer vuoto)");
        return;
    }

    bool isTester = MQLInfoInteger(MQL_TESTER) != 0;

    // ---------------------------------------------------------------
    // GENERA NOME FILE
    // ---------------------------------------------------------------
    string symbolClean = _Symbol;
    StringReplace(symbolClean, "/", "");
    StringReplace(symbolClean, "\\", "");
    StringReplace(symbolClean, ".", "");
    StringReplace(symbolClean, "#", "");

    string dateStr = TimeToString(TimeCurrent(), TIME_DATE);
    StringReplace(dateStr, ".", "-");

    string suffix = isTester ? "_backtest" : "_live";
    string filename = StringFormat("trades_ext_%s_%s%s.csv", symbolClean, dateStr, suffix);

    // ---------------------------------------------------------------
    // APRI FILE (FILE_COMMON come ExportTradesToCSV)
    // ---------------------------------------------------------------
    bool wroteToCommon = true;
    int fileHandle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ';');
    if (fileHandle == INVALID_HANDLE) {
        wroteToCommon = false;
        fileHandle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI, ';');
        if (fileHandle == INVALID_HANDLE) {
            PrintFormat("[EXPORT-EXT] Impossibile creare file: %s (Errore: %d)", filename, GetLastError());
            return;
        }
    }

    // ---------------------------------------------------------------
    // HEADER
    // ---------------------------------------------------------------
    FileWrite(fileHandle,
        "PositionId","OpenTime","CloseTime","Direction","Symbol","Volume",
        "RequestedOpenPrice","ExecutedOpenPrice","ClosePrice",
        "Commission","Swap","Profit","NetProfit","BalanceAfter","Duration_Minutes","MagicNumber",
        "Comment","CloseReason",
        "SpreadPtsAtOpen","SlippagePtsAtOpen","SL","TP",
        "ScorePctAtEntry","ThresholdBasePct","ThresholdEffPct","HurstSoftMult",
        "ThresholdMethodId","ThresholdMethod",
        "TFCoherenceMult","TFCoherenceConflicts","TFCoherenceSupports","TFCoherenceBlocked",
        "HurstTradeScore","HurstTradeThreshold","HurstReady","HurstAllowTrade",
        "HurstGlobal","HurstComposite","HurstCenter","HurstStdev",
        "RegimeM5","RegimeM5Text","RegimeH1","RegimeH1Text","RegimeH4","RegimeH4Text","RegimeD1","RegimeD1Text");

    int symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    int exported = 0;

    for (int i = 0; i < g_extendedTradesCount; i++) {
        ExtendedTradeRecord rec = g_extendedTrades[i];

        string dirStr = (rec.direction > 0) ? "Buy" : "Sell";

        // sanitize comment
        string c = rec.comment;
        StringReplace(c, ";", ",");
        StringReplace(c, "\n", " ");
        StringReplace(c, "\r", " ");

        FileWrite(fileHandle,
            (ulong)rec.positionId,
            TimeToString(rec.openTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS),
            TimeToString(rec.closeTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS),
            dirStr,
            rec.symbol,
            DoubleToString(rec.volume, 2),

            DoubleToString(rec.requestedOpenPrice, symbolDigits),
            DoubleToString(rec.executedOpenPrice, symbolDigits),
            DoubleToString(rec.closePrice, symbolDigits),

            DoubleToString(rec.commission, 2),
            DoubleToString(rec.swap, 2),
            DoubleToString(rec.profit, 2),
            DoubleToString(rec.netProfit, 2),
            DoubleToString(rec.balanceAfter, 2),
            (int)rec.durationMinutes,
            (long)rec.magic,

            c,
            rec.closeReason,

            DoubleToString(rec.spreadPtsAtOpen, 1),
            DoubleToString(rec.slippagePtsAtOpen, 1),
            DoubleToString(rec.sl, symbolDigits),
            DoubleToString(rec.tp, symbolDigits),

            DoubleToString(rec.scorePctAtEntry, 1),
            DoubleToString(rec.thresholdBasePct, 1),
            DoubleToString(rec.thresholdEffPct, 1),
            DoubleToString(rec.hurstSoftMult, 2),

            (int)rec.thresholdMethodId,
            ThresholdMethodToString(rec.thresholdMethodId),

            DoubleToString(rec.tfCoherenceMult, 2),
            (int)rec.tfCoherenceConflicts,
            (int)rec.tfCoherenceSupports,
            (int)rec.tfCoherenceBlocked,

            DoubleToString(rec.hurstTradeScore, 6),
            DoubleToString(rec.hurstTradeThreshold, 6),
            (int)rec.hurstReady,
            (int)rec.hurstAllowTrade,

            DoubleToString(rec.hurstGlobal, 6),
            DoubleToString(rec.hurstComposite, 6),
            DoubleToString(rec.hurstCenter, 6),
            DoubleToString(rec.hurstStdev, 6),

            (int)rec.regimeM5,
            RegimeToStringInt(rec.regimeM5),
            (int)rec.regimeH1,
            RegimeToStringInt(rec.regimeH1),
            (int)rec.regimeH4,
            RegimeToStringInt(rec.regimeH4),
            (int)rec.regimeD1,
            RegimeToStringInt(rec.regimeD1));

        exported++;
    }

    FileClose(fileHandle);
    PrintFormat("[EXPORT-EXT] Esportati %d trade estesi in %s (%s)", exported, filename, wroteToCommon ? "COMMON" : "LOCAL");
}

// ---------------------------------------------------------------------------
// v1.1: SOGLIA ADATTIVA OTSU -> YOUDEN
// Fase 1 (warm-up): Otsu - separazione bimodale degli score
// Fase 2 (feedback): Youden - massimizza TPR + TNR - 1 basato su profitti
// ---------------------------------------------------------------------------
double g_lastEntryScore = 0.0;            // Score % corrente (per nuovi trade)
bool   g_youdenReady = false;             // True quando abbiamo abbastanza trade per Youden
double g_youdenThreshold = 0.0;           // Soglia calcolata da Youden J
double g_otsuThreshold = 0.0;             // Soglia calcolata da Otsu
int    g_minTradesForYouden = 0;          // Minimo trade per passare a Youden (16)

// v1.1 FIX: Mappa ticket -> score per collegare correttamente score a trade
// Problema: g_lastEntryScore veniva sovrascritto prima della chiusura trade
// Soluzione: Array paralleli che mantengono score per ogni posizione aperta
ulong  g_openTickets[];                   // Ticket delle posizioni aperte
double g_openScores[];                    // Score al momento dell'apertura
int    g_openTicketsCount = 0;            // Numero posizioni tracciate
int    g_openTicketsMax = 0;              // Max posizioni = g_recentTradesMax

double g_hurstComposite = 0.0;           // H PESATO composito (calcolato dai dati)
double g_hurstConfidence = 0.0;          // Confidenza (0-1) basata su distanza da centro
double g_hurstTradeScore = 0.0;          // Trade score = |H - centro| * confidence / (stdev * f)
bool g_hurstAllowTrade = true;           // Flag: trade permessi?
bool g_hurstReady = false;               // True quando zona Hurst e soglia tradeScore sono da dati

// ---------------------------------------------------------------------------
// SOGLIA SCORE DINAMICA (derivata dalla distribuzione storica)
// ---------------------------------------------------------------------------
// Buffer circolare per memorizzare gli ultimi N score
// La soglia e calcolata come: mean(score) + stdev(score) * decay(H)
// Questo rende la soglia adattiva al comportamento recente del mercato
// ---------------------------------------------------------------------------
double g_scoreHistory[];                 // Buffer score storici
int g_scoreHistorySize = 0;              // Numero score memorizzati
int g_scoreHistoryIndex = 0;             // Indice corrente (buffer circolare)
double g_dynamicThreshold = 0.0;         // Soglia 100% data-driven (0 = non pronta)
// Dimensione buffer: potenza di 2 (calcolata dinamicamente)
int SCORE_HISTORY_MAX = 0;               // Calcolato in OnInit
bool g_scoreThresholdReady = false;      // True quando la soglia auto e calcolata dai dati

// SOMME INCREMENTALI per Score (O(1) invece di O(n))
double g_scoreSum = 0.0;                 // S(score)
double g_scoreSumSq = 0.0;               // S(score^2)
int    g_scoreOperationCount = 0;        // FIX: Contatore operazioni per ricalcolo periodico anti-drift

// ---------------------------------------------------------------------------
// DETECTOR INVERSIONE ORGANICO
// Score Momentum: traccia cambi direzione del consenso indicatori
// Regime Change: traccia transizioni regime Hurst
// RSI Divergence: rileva divergenze prezzo/RSI (classico, testato)
// ---------------------------------------------------------------------------

// Score Momentum: derivata dello score (segnale leading)
double g_prevScore = 0.0;                // Score della barra precedente
double g_scoreMomentum = 0.0;            // Cambio score: Score[t] - Score[t-1]
double g_scoreMomentumThreshold = 0.0;   // Soglia momentum = stdev(momentum) * decay(H)
double g_momentumHistory[];              // Buffer storico momentum per calcolo soglia
int g_momentumHistorySize = 0;
int g_momentumHistoryIndex = 0;
double g_momentumSum = 0.0;              // Somma incrementale momentum
double g_momentumSumSq = 0.0;            // Somma incrementale momentum^2
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
int g_swingsMax = 0;                     // Max swing = 16 (potenza di 2)
int g_divergenceSignal = 0;              // +1=bullish div, -1=bearish div, 0=nessuna
double g_divergenceStrength = 0.0;       // Forza divergenza (0-1)

// SOGLIA DIVERGENZA DATA-DRIVEN
// Traccia storia forze divergenza per calcolare soglia minima
double g_divergenceHistory[];            // Buffer storico forza divergenza
int g_divergenceHistorySize = 0;         // Dimensione buffer
int g_divergenceHistoryIndex = 0;        // Indice circolare
double g_divergenceSum = 0.0;            // Somma incrementale (O(1))
double g_divergenceSumSq = 0.0;          // Somma quadrati (O(1))
double g_divergenceMinThreshold = 0.0;   // Soglia iniziale = 0, calcolata dai dati
bool g_divergenceThresholdReady = false; // True quando calcolata dai dati

//  SOGLIA REVERSAL DATA-DRIVEN
// Tracciamo la storia della forza reversal e calcoliamo soglia data-driven
double g_reversalStrengthHistory[];      // Buffer storico forza reversal
int g_reversalHistorySize = 0;           // Dimensione buffer
int g_reversalHistoryIndex = 0;          // Indice circolare corrente
double g_reversalSum = 0.0;              // Somma incrementale (O(1))
double g_reversalSumSq = 0.0;            // Somma quadrati (O(1))
double g_reversalThreshold = 0.0;        // Soglia iniziale = 0, calcolata dai dati
bool g_reversalThresholdReady = false;   // True quando soglia calcolata dai dati

//  STOCHASTIC EXTREME DETECTION (ipercomprato/ipervenduto)
// Soglie standard: ipervenduto < 25%, ipercomprato > 75%
int g_stochExtremeSignal = 0;            // +1=ipervenduto (bullish reversal), -1=ipercomprato (bearish), 0=neutro
double g_stochExtremeStrength = 0.0;     // Forza segnale (0-1)

// OBV DIVERGENCE DETECTION (volume vs price)
int g_obvDivergenceSignal = 0;           // +1=bullish div (prezzo, OBV), -1=bearish (prezzo, OBV), 0=nessuna
double g_obvDivergenceStrength = 0.0;    // Forza divergenza OBV (0-1)

// DYNAMIC BUFFER RESIZE: tracciamento per resize automatico
// Init bootstrap: centro range teorico (0.1+0.9)/2 = 0.5
double g_lastHurstForResize = (HURST_RANGE_MIN + HURST_RANGE_MAX) / 2.0;  // Bootstrap
int g_lastMomentumBufferSize = 0;        // Ultima dimensione buffer momentum
int g_lastDivergenceBufferSize = 0;      // Ultima dimensione buffer divergence  
int g_lastReversalBufferSize = 0;        // Ultima dimensione buffer reversal
// DATA-DRIVEN: Soglia ridimensionamento = 2sigma(H) storico (cambio regime a 95% confidenza)
// Non pi valore fisso 0.15, ma derivato dalla variabilit empirica di Hurst

// COSTANTE CACHED: evita 4x SymbolInfoDouble per barra
double g_pointValue = 0.0;               // SYMBOL_POINT (calcolato 1x in OnInit)

//--- Handles indicatori per tutti i timeframe (inizializzati a INVALID_HANDLE per sicurezza)
int emaHandle_M5 = INVALID_HANDLE, emaHandle_H1 = INVALID_HANDLE, emaHandle_H4 = INVALID_HANDLE, emaHandle_D1 = INVALID_HANDLE;
int rsiHandle_M5 = INVALID_HANDLE, rsiHandle_H1 = INVALID_HANDLE, rsiHandle_H4 = INVALID_HANDLE, rsiHandle_D1 = INVALID_HANDLE;
int macdHandle_M5 = INVALID_HANDLE, macdHandle_H1 = INVALID_HANDLE, macdHandle_H4 = INVALID_HANDLE, macdHandle_D1 = INVALID_HANDLE;
int bbHandle_M5 = INVALID_HANDLE, bbHandle_H1 = INVALID_HANDLE, bbHandle_H4 = INVALID_HANDLE, bbHandle_D1 = INVALID_HANDLE;
int atrHandle_M5 = INVALID_HANDLE, atrHandle_H1 = INVALID_HANDLE, atrHandle_H4 = INVALID_HANDLE, atrHandle_D1 = INVALID_HANDLE;
int adxHandle_M5 = INVALID_HANDLE, adxHandle_H1 = INVALID_HANDLE, adxHandle_H4 = INVALID_HANDLE, adxHandle_D1 = INVALID_HANDLE;
int obvHandle_M5 = INVALID_HANDLE, obvHandle_H1 = INVALID_HANDLE, obvHandle_H4 = INVALID_HANDLE, obvHandle_D1 = INVALID_HANDLE;
// NUOVI INDICATORI TREND (da v1.0)
int psarHandle_M5 = INVALID_HANDLE, psarHandle_H1 = INVALID_HANDLE, psarHandle_H4 = INVALID_HANDLE, psarHandle_D1 = INVALID_HANDLE;
int smaFastHandle_M5 = INVALID_HANDLE, smaFastHandle_H1 = INVALID_HANDLE, smaFastHandle_H4 = INVALID_HANDLE, smaFastHandle_D1 = INVALID_HANDLE;
int smaSlowHandle_M5 = INVALID_HANDLE, smaSlowHandle_H1 = INVALID_HANDLE, smaSlowHandle_H4 = INVALID_HANDLE, smaSlowHandle_D1 = INVALID_HANDLE;
int ichimokuHandle_M5 = INVALID_HANDLE, ichimokuHandle_H1 = INVALID_HANDLE, ichimokuHandle_H4 = INVALID_HANDLE, ichimokuHandle_D1 = INVALID_HANDLE;
int stochHandle_M5 = INVALID_HANDLE, stochHandle_H1 = INVALID_HANDLE, stochHandle_H4 = INVALID_HANDLE, stochHandle_D1 = INVALID_HANDLE;

//--- Struttura dati per timeframe
struct TimeFrameData {
    double ema[];
    double rsi[];           // Usato per divergenza (non vota inversione)
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
    // NUOVI INDICATORI TREND (da v1.0)
    double psar[];          // Parabolic SAR
    double sma_fast[];      // SMA veloce
    double sma_slow[];      // SMA lenta
    double ichimoku_tenkan[];   // Tenkan-sen (conversion line)
    double ichimoku_kijun[];    // Kijun-sen (base line)
    double ichimoku_senkou_a[]; // Senkou Span A
    double ichimoku_senkou_b[]; // Senkou Span B
    // INDICATORI MEAN-REVERSION (votano inversione)
    double stoch_main[];    // Stochastic %K
    double stoch_signal[];  // Stochastic %D
    MqlRates rates[];
    
    // Valori organici calcolati dinamicamente
    double atr_avg;         // Media ATR calcolata sulle ultime N barre
    double adx_avg;         // Media ADX calcolata sulle ultime N barre
    double adx_stddev;      // Deviazione standard ADX
    double adx_threshold;   // Soglia ADX organica = avg + decay(H)*stddev
    bool   isDataReady;     // Flag: abbastanza dati per calcoli organici
    
    // CENTRI ADATTIVI HURST-DRIVEN - Calcolati da CalculateEmpiricalThresholds()
    // Metodo varia in base al regime: EMA (trending), Mediana (random), TrimmedMean (reverting)
    double rsi_center;      // Centro adattivo RSI ultime N barre
    double stoch_center;    // Centro adattivo Stochastic ultime N barre
    
    // SCALE EMPIRICHE - Derivate dalla volatilita dei dati
    double rsi_scale;       // Stdev empirico RSI * scale(H)
    double stoch_scale;     // Stdev empirico Stochastic * scale(H)
    double obv_scale;       // Stdev empirico variazioni OBV * scale(H)
    
    // ADX PERCENTILI - Derivati dalla distribuzione storica
    double adx_p25;         // 38esimo percentile ADX (range "basso")
    double adx_p75;         // 62esimo percentile ADX (range "alto")
    
    // Riferimento ai periodi organici del TF (impostato in LoadTimeFrameData)
    OrganicPeriods organic; // Periodi e peso organico del timeframe
};

TimeFrameData tfData_M5, tfData_H1, tfData_H4, tfData_D1;

//--- Flag TF attivi (aggiornati ad ogni tick in base ai dati disponibili)
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
    //  STEP 0: INIZIALIZZAZIONE BUFFER (data-driven da Hurst)
    // Dimensioni derivate da periodi naturali  scale^n(H)
    // Con g_hurstGlobal = 0.5 (default): scale  1.41
    // ---------------------------------------------------------------
    // TRADE_SCORE: GetBufferXLarge() = H1  scale(H)  48 (H=0.5)
    TRADE_SCORE_HISTORY_MAX = GetBufferXLarge();    // ~48-68 a seconda di H
    // HURST:  RIDOTTO a 64 per evitare stack overflow e accelerare warmup
    // 64 campioni sono sufficienti per statistiche robuste (stesso di TradeScore)
    HURST_HISTORY_MAX = 64;  // Fisso a 64 per performance e stabilit
    // SCORE: periodo H1 empirico  scale(H)  scale(H) (non  2 fisso)
    // Bootstrap: usa GetBootstrapSafeBars() = g_naturalPeriod_Min  2 (dinamico)
    int scoreBase = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapSafeBars();
    SCORE_HISTORY_MAX = (int)MathRound(GetDataDrivenBufferSize(scoreBase, g_hurstGlobal, 4) * GetOrganicScale(GetDefaultHurst()));
    
    // RILEVAMENTO BACKTEST E OTTIMIZZAZIONE AUTOMATICA
    g_isBacktest = (bool)MQLInfoInteger(MQL_TESTER);
    g_enableLogsEffective = EnableLogs && !g_isBacktest;
    g_barsSinceLastRecalc = 0;
    
    if (g_isBacktest) {
        Print("-----------------------------------------------------------------");
        Print("BACKTEST MODE ATTIVO - performance ottimizzata");
        if (RecalcEveryBars > 0) {
            PrintFormat("   Ricalcolo organico: ogni %d barre (invece di ogni barra)", RecalcEveryBars);
            PrintFormat("   Speedup atteso: ~%dx rispetto al normale", RecalcEveryBars);
        } else {
            Print("   Ricalcolo organico: ogni barra (usa RecalcEveryBars>0 per velocizzare)");
            Print("   Consiglio: imposta RecalcEveryBars=100 per backtest molto piu veloce");
        }
        Print("   Sistema: SCALE 2^H (data-driven)");
        Print("   Nota log: i log dettagliati sono ridotti in backtest");
        Print("-----------------------------------------------------------------");
    }
    
    Print("[INIT] Avvio EA Jarvis v4 FULL DATA-DRIVEN - periodi e pesi dai dati");
    
    // CACHE COSTANTI SIMBOLO (evita chiamate API ripetute)
    g_pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // Fallback basato su convenzione mercato (dati empirici)
    // Forex standard: 0.00001 (5 decimali), JPY/XAU: 0.01 (2-3 decimali)
    if (g_pointValue <= 0) {
        // Determina se coppia JPY-like dal nome simbolo
        string upperSymbol = _Symbol;
        StringToUpper(upperSymbol);
        if (StringFind(upperSymbol, "JPY") >= 0 || StringFind(upperSymbol, "XAU") >= 0) {
            g_pointValue = 0.01;  // Coppie JPY o Oro: point tipico 0.01
        } else {
            g_pointValue = 0.00001;  // Forex standard: 5 decimali
        }
    }
    
    // FIX: Calcola e cacha Magic Number UNA VOLTA (evita ricalcolo costante)
    g_uniqueMagicNumber = CalculateUniqueMagicNumber();
    PrintFormat("[INIT] Magic Number unico per %s: %d", _Symbol, g_uniqueMagicNumber);

    // Circuit Breaker (lettera C): init stato e buffer
    CB_Init();
    
    // ---------------------------------------------------------------
    // STEP 1: PRE-CARICAMENTO DATI STORICI
    // Carica abbastanza barre per calcolare autocorrelazione e cicli
    // Se i dati non sono sufficienti, il TF viene DISABILITATO (no fallback!)
    // ---------------------------------------------------------------
    Print("[INIT] Pre-caricamento dati storici per analisi naturale...");
    
    // Calcola periodi naturali E forza autocorrelazione per ogni TF
    // Entrambi derivati COMPLETAMENTE dai dati!
    NaturalPeriodResult result_M5 = CalculateNaturalPeriodForTF(PERIOD_M5);
    NaturalPeriodResult result_H1 = CalculateNaturalPeriodForTF(PERIOD_H1);
    NaturalPeriodResult result_H4 = CalculateNaturalPeriodForTF(PERIOD_H4);
    NaturalPeriodResult result_D1 = CalculateNaturalPeriodForTF(PERIOD_D1);
    
    // SALVA PERIODI EMPIRICI per uso globale (sostituiscono DEFAULT)
    g_naturalPeriod_M5 = result_M5.valid ? result_M5.period : BOOTSTRAP_MIN_BARS;
    g_naturalPeriod_H1 = result_H1.valid ? result_H1.period : BOOTSTRAP_MIN_BARS;
    g_naturalPeriod_H4 = result_H4.valid ? result_H4.period : BOOTSTRAP_MIN_BARS;
    g_naturalPeriod_D1 = result_D1.valid ? result_D1.period : BOOTSTRAP_MIN_BARS;
    
    // Base sistema = minimo tra TF attivi (pi reattivo)
    g_naturalPeriod_Min = INT_MAX;  // Sentinella massima
    if (result_M5.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_M5.period);
    if (result_H1.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_H1.period);
    if (result_H4.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_H4.period);
    if (result_D1.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_D1.period);
    if (g_naturalPeriod_Min == INT_MAX) g_naturalPeriod_Min = BOOTSTRAP_MIN_BARS;  // Fallback empirico
    
    // DATA-DRIVEN: Calcola base di scala empirica dai rapporti TF
    CalculateEmpiricalScaleBase();
    
    // PURO: Disabilita TF senza dati sufficienti
    g_dataReady_M5 = result_M5.valid;
    g_dataReady_H1 = result_H1.valid;
    g_dataReady_H4 = result_H4.valid;
    g_dataReady_D1 = result_D1.valid;
    
    if (!result_M5.valid) Print("[INIT] M5: dati insufficienti - TF DISABILITATO");
    if (!result_H1.valid) Print("[INIT] H1: dati insufficienti - TF DISABILITATO");
    if (!result_H4.valid) Print("[INIT] H4: dati insufficienti - TF DISABILITATO");
    if (!result_D1.valid) Print("[INIT] D1: dati insufficienti - TF DISABILITATO");
    
    // Verifica che almeno un TF sia attivo
    if (!g_dataReady_M5 && !g_dataReady_H1 && !g_dataReady_H4 && !g_dataReady_D1) {
        Print("[INIT] ERRORE: nessun timeframe ha dati sufficienti - EA non puo operare");
        return INIT_FAILED;
    }
    
    // ---------------------------------------------------------------
    // STEP 2: CALCOLO PESI EMPIRICI (ESPONENTE DI HURST)
    // peso_TF = hurstExponent_TF / somma(hurstExponent)
    // H > g_hurstRandomHigh: trending -> peso maggiore
    // H in [g_hurstRandomLow, g_hurstRandomHigh]: random -> zona no-trade
    // H < g_hurstRandomLow: mean-reverting -> peso maggiore
    // 100% derivato dai DATI, non dai minuti del timeframe!
    // ---------------------------------------------------------------
    double totalHurst = 0;
    // hurstExponent validato nel range [HURST_RANGE_MIN, HURST_RANGE_MAX]
    if (result_M5.valid) totalHurst += result_M5.hurstExponent;
    if (result_H1.valid) totalHurst += result_H1.hurstExponent;
    if (result_H4.valid) totalHurst += result_H4.hurstExponent;
    if (result_D1.valid) totalHurst += result_D1.hurstExponent;
    
    // VALIDATO: Protezione divisione per zero
    if (totalHurst <= 0) totalHurst = GetDefaultHurst();  // Fallback empirico
    
    // VALIDATO: Pesi sempre >= 0 e normalizzati (sommano a 1.0 se almeno un TF valido)
    double weight_M5 = result_M5.valid ? (result_M5.hurstExponent / totalHurst) : 0;
    double weight_H1 = result_H1.valid ? (result_H1.hurstExponent / totalHurst) : 0;
    double weight_H4 = result_H4.valid ? (result_H4.hurstExponent / totalHurst) : 0;
    double weight_D1 = result_D1.valid ? (result_D1.hurstExponent / totalHurst) : 0;
    
    PrintFormat("[INIT] Periodi naturali: M5=%d H1=%d H4=%d D1=%d",
        result_M5.period, result_H1.period, result_H4.period, result_D1.period);
    // NOTA: T/M/R sono etichette preliminari - la zona esatta sara' calcolata dai dati storici
    PrintFormat("[INIT] Hurst: M5=%.3f H1=%.3f H4=%.3f D1=%.3f",
        result_M5.hurstExponent, result_H1.hurstExponent, result_H4.hurstExponent, result_D1.hurstExponent);
    PrintFormat("[INIT] Pesi empirici (Hurst): M5=%.2f H1=%.2f H4=%.2f D1=%.2f",
        weight_M5, weight_H1, weight_H4, weight_D1);
    PrintFormat("[INIT] TF attivi: M5=%s H1=%s H4=%s D1=%s",
        StateLabel(g_dataReady_M5), StateLabel(g_dataReady_H1),
        StateLabel(g_dataReady_H4), StateLabel(g_dataReady_D1));
    
    // ---------------------------------------------------------------
    // STEP 3: CALCOLO PERIODI ORGANICI (solo per TF attivi)
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
        Print("PERIODI E PESI 100% DATA-DRIVEN (Hurst + Rapporti f)");
        Print("---------------------------------------------------------------");
        if (g_dataReady_M5) LogOrganicPeriods("M5", g_organic_M5);
        if (g_dataReady_H1) LogOrganicPeriods("H1", g_organic_H1);
        if (g_dataReady_H4) LogOrganicPeriods("H4", g_organic_H4);
        if (g_dataReady_D1) LogOrganicPeriods("D1", g_organic_D1);
        Print("---------------------------------------------------------------");
        Print("");
    }
    
    // ---------------------------------------------------------------
    // STEP 4: INIZIALIZZA FILTRO HURST NO-TRADE ZONE (preliminare)
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
        Print("FILTRO HURST NO-TRADE ZONE ATTIVO (preliminare)");
        if (RecalcEveryBars > 0) {
            PrintFormat("   Ricalcolo: ogni %d barre (ottimizzato per backtest)", RecalcEveryBars);
        } else {
            Print("   Ricalcolo: ogni nuova barra");
        }
        Print("   Zona adattiva e buffer verranno inizializzati in STEP 6");
        Print("---------------------------------------------------------------");
        Print("");
    } else {
        Print("[INIT] Filtro Hurst NO-TRADE ZONE: DISABILITATO");
        g_hurstAllowTrade = true;
    }
    
    // ---------------------------------------------------------------
    // STEP 5: INIZIALIZZA SOGLIA SCORE DINAMICA
    // Se AutoScoreThreshold=true, la soglia sara' derivata dalla
    // distribuzione storica degli score. Altrimenti usa valore manuale.
    // ---------------------------------------------------------------
    InitScoreHistoryBuffer();
    if (AutoScoreThreshold) {
        //  VALIDATO: minSamples derivato dal periodo naturale M5  scale
        int minSamplesOrganic = GetBufferSmall();  // ~12 campioni
        // Percentuale buffer = decay(H) (~25% per H=0.5, ~38% per H=0.7)
        double bufferFraction = GetOrganicDecayPow(GetDefaultHurst(), 2.0);
        int minSamplesForInit = MathMax(minSamplesOrganic, (int)MathCeil(SCORE_HISTORY_MAX * bufferFraction));
        Print("");
        Print("---------------------------------------------------------------");
        Print("SOGLIA SCORE 100% DERIVATA DAI DATI");
        Print("   Formula: threshold = mean_score + stdev_score * decay(H)");
        PrintFormat("   Buffer: %d campioni | Ready dopo %d campioni (~%d%% del buffer)", 
            SCORE_HISTORY_MAX, minSamplesForInit, (int)MathRound(100.0 * minSamplesForInit / SCORE_HISTORY_MAX));
        double decayH2Log = GetOrganicDecayPow(GetDefaultHurst(), 2.0);  // ~0.25 per H empirico
        PrintFormat("   Limiti: [%.1f%%, %.1f%%] (decay^2 a 1-decay^2)", decayH2Log * 100, (1.0 - decayH2Log) * 100);
        Print("---------------------------------------------------------------");
        Print("");
    } else {
        PrintFormat("[INIT] Soglia score MANUALE: %.1f%%", ScoreThreshold);
    }
    
    // ---------------------------------------------------------------
    // STEP 6: INIZIALIZZA BUFFER STORICO HURST
    // Per calcolo zona random adattiva: centro +/- (stdev_H * decay(H))
    // ---------------------------------------------------------------
    InitHurstHistoryBuffer();
    
    // Pre-carica il buffer Hurst dai dati storici
    // Cosi' il trading puo' iniziare SUBITO invece di aspettare warm-up!
    PreloadHurstBufferFromHistory();
    
    if (EnableHurstFilter) {
        Print("");
        Print("---------------------------------------------------------------");
        Print("FILTRO HURST ADATTIVO ATTIVO");
        if (g_hurstZoneReady) {
            Print("   Buffer Hurst GIA PRONTO (pre-caricato da storia)");
        } else {
            Print("   Zona e soglie verranno calcolate dai dati di mercato");
        }
        PrintFormat("   Buffer Hurst: %d/%d campioni | Ready: %s", 
            g_hurstHistorySize, HURST_HISTORY_MAX, g_hurstZoneReady ? "SI" : "NO");
        PrintFormat("   Buffer TradeScore: %d campioni | Ready dopo ~%d campioni",
            TRADE_SCORE_HISTORY_MAX, (int)MathCeil(TRADE_SCORE_HISTORY_MAX * GetOrganicDecayPow(GetDefaultHurst(), 2.0)));
        Print("   Formula zona: centro = mean(H), margine = stdev(H) * decay(H)");
        Print("   Formula soglia: mean(tradeScore) + stdev(tradeScore) * decay(H)");
        Print("---------------------------------------------------------------");
        Print("");
    }
    
    trade.SetExpertMagicNumber(g_uniqueMagicNumber);  // FIX: Usa cache
    trade.SetMarginMode();
    trade.SetTypeFillingBySymbol(_Symbol);
    trade.SetDeviationInPoints(MaxSlippage);
    
    if (g_enableLogsEffective) {
        PrintFormat("[INIT] Magic Number unico per %s: %d (base=%d)", 
            _Symbol, g_uniqueMagicNumber, MagicNumber);
    }
    
    if (!InitializeIndicators()) {
        Print("[ERROR] Errore inizializzazione indicatori");
        return INIT_FAILED;
    }
    
    // ---------------------------------------------------------------
    // FIX: Verifica che almeno un indicatore DIREZIONALE sia abilitato
    // Senza indicatori attivi, lo score sara' sempre 0 e nessun trade eseguito
    // v1.1: RSI, Stoch, OBV sono MEAN-REVERSION, votano nella direzione inversione
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
        Print("[INIT] ERRORE: nessun indicatore TREND abilitato");
        Print("   Almeno uno tra EMA, MACD, BB, Heikin, ADX, PSAR, SMA, Ichimoku deve essere TRUE");
        Print("   EA non puo generare segnali di trading");
        return INIT_FAILED;
    }
    PrintFormat("[INIT] %d indicatori TREND (votano) + %d MEAN-REVERSION (votano inversione)", 
        numTrendIndicators, numBlockIndicators);
    
    // FIX: Salva periodi iniziali per rilevamento cambi futuri
    SaveCurrentPeriodsAsPrevious();
    
    // FIX: Inizializza warmup period
    g_eaStartTime = TimeCurrent();
    g_warmupComplete = false;
    // Warmup = scale(H) * naturalPeriod pi lungo disponibile
    int longestPeriod = MathMax(MathMax(g_organic_M5.naturalPeriod, g_organic_H1.naturalPeriod),
                                MathMax(g_organic_H4.naturalPeriod, g_organic_D1.naturalPeriod));
    // Minimo warmup derivato dal periodo empirico H1  scale
    int baseH1 = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapSafeBars();
    int minWarmupBars = GetDataDrivenBufferSize(baseH1, GetDefaultHurst(), 2);
    double warmupScale = GetOrganicScale(GetDefaultHurst());  // scala da H empirico
    g_warmupBarsRequired = MathMax(minWarmupBars, (int)MathRound(longestPeriod * warmupScale));
    PrintFormat("[INIT] Warmup: %d barre richieste prima del trading", g_warmupBarsRequired);
    
    // ---------------------------------------------------------------
    //  INIZIALIZZA STATISTICHE TRADING
    // ---------------------------------------------------------------
    ZeroMemory(g_stats);
    g_stats.peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // Buffer trade recenti = periodo empirico H1  scale
    int baseForTrades = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapSafeBars();
    g_recentTradesMax = GetDataDrivenBufferSize(baseForTrades, GetDefaultHurst(), 2);
    
    //  v1.1: Inizializza sistema Otsu  Youden
    int baseForYouden = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    g_minTradesForYouden = GetDataDrivenBufferSize(baseForYouden, GetDefaultHurst(), 1);
    g_youdenReady = false;
    g_youdenThreshold = 0.0;
    g_otsuThreshold = 0.0;
    g_lastEntryScore = 0.0;
    
    //  v1.1 FIX: Inizializza mappa ticket  score
    g_openTicketsMax = g_recentTradesMax;  // Stesso buffer size
    ArrayResize(g_openTickets, g_openTicketsMax);
    ArrayResize(g_openScores, g_openTicketsMax);
    ArrayInitialize(g_openTickets, 0);
    ArrayInitialize(g_openScores, 0.0);
    g_openTicketsCount = 0;
    
    // ---------------------------------------------------------------
    //  INIZIALIZZA DETECTOR INVERSIONE
    // ---------------------------------------------------------------
    InitReversalDetectors();
    ArrayResize(g_recentTrades, g_recentTradesMax);
    g_recentTradesCount = 0;
    g_recentTradesIndex = 0;
    
    PrintFormat("[INIT] Statistiche trading inizializzate | Buffer ultimi %d trade | Equity iniziale: %.2f", 
        g_recentTradesMax, g_stats.peakEquity);
    
    //  v1.1: Log sistema Otsu  Youden
    Print("");
    Print("---------------------------------------------------------------");
    Print("SOGLIA ADATTIVA: OTSU -> YOUDEN (100% DATA-DRIVEN)");
    Print("---------------------------------------------------------------");
    PrintFormat("   Fase 1 (warm-up): OTSU - separazione bimodale score");
    PrintFormat("   Fase 2 (>=%d trade): YOUDEN - massimizza (TPR+TNR-1)", g_minTradesForYouden);
    double decayBounds = GetOrganicDecayPow(GetDefaultHurst(), 2.0);
    PrintFormat("   Bounds: P%.1f%% <-> P%.1f%% (data-driven da Hurst)", decayBounds * 100.0, (1.0 - decayBounds) * 100.0);
    Print("   Tutti i parametri derivati da 2^H e dai dati");
    Print("---------------------------------------------------------------");
    
    // ---------------------------------------------------------------
    // RIEPILOGO STATO BUFFER - Trading pronto?
    // ---------------------------------------------------------------
    Print("");
    Print("---------------------------------------------------------------");
    Print("STATO BUFFER E PRONTEZZA TRADING");
    Print("---------------------------------------------------------------");
    PrintFormat("   Buffer Hurst: %d/%d | Ready: %s", 
        g_hurstHistorySize, HURST_HISTORY_MAX, g_hurstZoneReady ? "SI" : "NO");
    PrintFormat("   Buffer TradeScore: %d/%d | Ready: %s", 
        g_tradeScoreHistorySize, TRADE_SCORE_HISTORY_MAX, g_tradeScoreReady ? "SI" : "NO");
    PrintFormat("   g_hurstReady: %s", g_hurstReady ? "SI" : "NO");
    PrintFormat("   Buffer Score Indicatori: %d/%d | Ready: %s (fallback: soglia manuale %.1f%%)", 
        g_scoreHistorySize, SCORE_HISTORY_MAX, g_scoreThresholdReady ? "SI" : "NO", ScoreThreshold);
    
    if (g_hurstReady) {
        Print("   TRADING PRONTO IMMEDIATAMENTE");
    } else {
        Print("   Warm-up parziale richiesto per alcuni buffer");
    }
    Print("---------------------------------------------------------------");
    Print("");
    
    Print("[INIT] EA DATA-DRIVEN inizializzato - periodi e pesi auto-calcolati dai dati");
    
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
//|  RICALCOLO COMPLETO: Periodi naturali, pesi, e periodi organici|
//| Chiamato ad ogni nuova barra per adattarsi ai cambi di regime    |
//|  OTTIMIZZATO: Usa cache per evitare ricalcoli costosi          |
//+------------------------------------------------------------------+
void RecalculateOrganicSystem()
{
    // ---------------------------------------------------------------
    //  FIX: RILEVAMENTO GAP DI PREZZO - Invalida cache se gap > ATR * f
    // Questo garantisce che cambi di regime improvvisi vengano gestiti
    // ---------------------------------------------------------------
    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if (g_cacheValid && g_lastCachePrice > 0 && g_lastCacheATR > 0) {
        double priceChange = MathAbs(currentPrice - g_lastCachePrice);
        double gapThreshold = g_lastCacheATR * GetOrganicScale(g_hurstGlobal);  // Gap = ATR * scale(H)
        
        if (priceChange > gapThreshold) {
            g_cacheValid = false;  // Invalida cache su gap
            if (g_enableLogsEffective) {
                PrintFormat("[RECALC] GAP rilevato: %.5f > %.5f (ATR*scale) - cache invalidata", 
                    priceChange, gapThreshold);
            }
        }
    }
    
    // ---------------------------------------------------------------
    // CHECK CACHE - Ricalcola Hurst SOLO ogni N cicli (molto costoso!)
    // ---------------------------------------------------------------
    // Intervallo ricalcolo: derivato dal periodo M5 x scale
    // Intervallo ricalcolo Hurst = periodo minimo empirico  scale(H)
    int recalcBase = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    int hurstRecalcDivisor = GetDataDrivenBufferSize(recalcBase, GetDefaultHurst(), 1);  // ~17 empirico
    //  FIX: Con RecalcEveryBars=0, intervallo minimo=1 per riempire buffer velocemente
    int hurstRecalcInterval = (RecalcEveryBars <= 0) ? 1 : MathMax(4, RecalcEveryBars / hurstRecalcDivisor);
    
    bool needFullHurstRecalc = false;
    //  FIX CRITICO: Con RecalcEveryBars=0, FORZA ricalcolo ogni barra per riempire buffer
    if (RecalcEveryBars <= 0) {
        needFullHurstRecalc = true;
        g_hurstRecalcCounter = 0;
        if (g_enableLogsEffective && g_hurstHistorySize < 5) {
            Print("[DEBUG] needFullHurstRecalc=TRUE (RecalcEveryBars=0)");
        }
    }
    else if (!g_cacheValid || g_hurstRecalcCounter >= hurstRecalcInterval) {
        needFullHurstRecalc = true;
        g_hurstRecalcCounter = 0;
    } else {
        g_hurstRecalcCounter++;
    }
    
    NaturalPeriodResult result_M5, result_H1, result_H4, result_D1;
    
    //  PERIODI NATURALI: ricalcolo ad ogni nuova barra H4 (struttura mercato)
    // Indipendente dal timeframe del chart - usa sempre H4 come trigger
    bool recalcNaturalPeriods = false;
    datetime currentH4BarTime = iTime(_Symbol, PERIOD_H4, 0);
    if (g_lastH4BarTime == 0 || currentH4BarTime != g_lastH4BarTime) {
        recalcNaturalPeriods = true;
        g_lastH4BarTime = currentH4BarTime;
    }
    
    if (needFullHurstRecalc) {
        //  FIX CRITICO: Se cache non inizializzata, forza calcolo completo
        if (!g_cacheValid || recalcNaturalPeriods) {
            //  DEBUG: Log per verificare che entriamo nel ramo corretto
            if (g_hurstHistorySize < 3) {
                PrintFormat("[FIX CHECK] RICALCOLO COMPLETO: g_cacheValid=%s recalcNaturalPeriods=%s", 
                    g_cacheValid ? "true" : "false", recalcNaturalPeriods ? "true" : "false");
            }
            // RICALCOLO COMPLETO: periodi naturali + Hurst
            result_M5 = CalculateNaturalPeriodForTF(PERIOD_M5);
            result_H1 = CalculateNaturalPeriodForTF(PERIOD_H1);
            result_H4 = CalculateNaturalPeriodForTF(PERIOD_H4);
            result_D1 = CalculateNaturalPeriodForTF(PERIOD_D1);
            
            // Aggiorna periodi naturali globali
            if (result_M5.valid) g_naturalPeriod_M5 = result_M5.period;
            if (result_H1.valid) g_naturalPeriod_H1 = result_H1.period;
            if (result_H4.valid) g_naturalPeriod_H4 = result_H4.period;
            if (result_D1.valid) g_naturalPeriod_D1 = result_D1.period;
            
            // Ricalcola anche g_naturalPeriod_Min
            g_naturalPeriod_Min = INT_MAX;
            if (result_M5.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_M5.period);
            if (result_H1.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_H1.period);
            if (result_H4.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_H4.period);
            if (result_D1.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_D1.period);
            if (g_naturalPeriod_Min == INT_MAX) g_naturalPeriod_Min = BOOTSTRAP_MIN_BARS;
            
            //  DEBUG: Verifica valid dopo calcolo
            if (g_hurstHistorySize < 3) {
                PrintFormat("[FIX CHECK] Result valid: M5=%s H1=%s H4=%s D1=%s", 
                    result_M5.valid ? "TRUE" : "FALSE", result_H1.valid ? "TRUE" : "FALSE",
                    result_H4.valid ? "TRUE" : "FALSE", result_D1.valid ? "TRUE" : "FALSE");
            }
        } else {
            // RICALCOLO SOLO HURST (normale): riusa periodi naturali esistenti
            result_M5 = g_cachedResult_M5;
            result_H1 = g_cachedResult_H1;
            result_H4 = g_cachedResult_H4;
            result_D1 = g_cachedResult_D1;
        
            // Ricalcola SOLO esponente Hurst (leggero), non periodi naturali (pesante)
            //  OTTIMIZZATO: usa 128 barre per R/S (ridotto da 256 per stack safety)
            int barsForHurst = 128;  //  RIDOTTO da 256 a 128 per prevenire stack overflow
            int minBarsForValidH = 64;  // Minimo per evitare fallback a H=0.5
            if (g_dataReady_M5) {
                MqlRates rates[];
                ArraySetAsSeries(rates, true);
                int copied = CopyRates(_Symbol, PERIOD_M5, 1, barsForHurst, rates);
                if (copied >= minBarsForValidH) {
                    result_M5.hurstExponent = CalculateHurstExponent(rates, copied);
                    UpdateHurstLimits(result_M5.hurstExponent);  //  Aggiorna limiti empirici
                }
            }
            if (g_dataReady_H1) {
                MqlRates rates[];
                ArraySetAsSeries(rates, true);
                int copied = CopyRates(_Symbol, PERIOD_H1, 1, barsForHurst, rates);
                if (copied >= minBarsForValidH) {
                    result_H1.hurstExponent = CalculateHurstExponent(rates, copied);
                    UpdateHurstLimits(result_H1.hurstExponent);  //  Aggiorna limiti empirici
                }
            }
            if (g_dataReady_H4) {
                MqlRates rates[];
                ArraySetAsSeries(rates, true);
                int copied = CopyRates(_Symbol, PERIOD_H4, 1, barsForHurst, rates);
                if (copied >= minBarsForValidH) {
                    result_H4.hurstExponent = CalculateHurstExponent(rates, copied);
                    UpdateHurstLimits(result_H4.hurstExponent);  //  Aggiorna limiti empirici
                }
            }
            if (g_dataReady_D1) {
                MqlRates rates[];
                ArraySetAsSeries(rates, true);
                int copied = CopyRates(_Symbol, PERIOD_D1, 1, barsForHurst, rates);
                if (copied >= minBarsForValidH) {
                    result_D1.hurstExponent = CalculateHurstExponent(rates, copied);
                    UpdateHurstLimits(result_D1.hurstExponent);  //  Aggiorna limiti empirici
                }
            }
        }
        
        //  AGGIUNTA: Calcola Hurst composito pesato e aggiorna buffer
        double hurstWeightedSum = 0;
        double weightSum = 0;
        
        if (result_M5.valid && result_M5.hurstExponent > 0 && result_M5.hurstExponent < 1.0) {
            hurstWeightedSum += result_M5.hurstExponent * g_organic_M5.weight;
            weightSum += g_organic_M5.weight;
        }
        if (result_H1.valid && result_H1.hurstExponent > 0 && result_H1.hurstExponent < 1.0) {
            hurstWeightedSum += result_H1.hurstExponent * g_organic_H1.weight;
            weightSum += g_organic_H1.weight;
        }
        if (result_H4.valid && result_H4.hurstExponent > 0 && result_H4.hurstExponent < 1.0) {
            hurstWeightedSum += result_H4.hurstExponent * g_organic_H4.weight;
            weightSum += g_organic_H4.weight;
        }
        if (result_D1.valid && result_D1.hurstExponent > 0 && result_D1.hurstExponent < 1.0) {
            hurstWeightedSum += result_D1.hurstExponent * g_organic_D1.weight;
            weightSum += g_organic_D1.weight;
        }
        
        // Aggiorna buffer Hurst con valore composito
        if (weightSum > 0) {
            double hComposite = hurstWeightedSum / weightSum;
            
            int hurstMax = ArraySize(g_hurstHistory);
            if (hurstMax > 0) {
                // Se buffer pieno, sottrai valore vecchio
                if (g_hurstHistorySize == hurstMax) {
                    double oldValue = g_hurstHistory[g_hurstHistoryIndex];
                    g_hurstSum -= oldValue;
                    g_hurstSumSq -= oldValue * oldValue;
                    if (g_hurstSum < 0) g_hurstSum = 0;
                    if (g_hurstSumSq < 0) g_hurstSumSq = 0;
                }
                
                // Aggiungi nuovo valore
                g_hurstHistory[g_hurstHistoryIndex] = hComposite;
                g_hurstSum += hComposite;
                g_hurstSumSq += hComposite * hComposite;
                g_hurstHistoryIndex = (g_hurstHistoryIndex + 1) % hurstMax;
                
                if (g_hurstHistorySize < hurstMax) {
                    g_hurstHistorySize++;
                }
                
                // Ricalcola centro e stdev se buffer sufficientemente pieno
                int minSamples = MathMax(10, hurstMax / 10);  // Minimo 10 campioni o 10% del buffer
                if (g_hurstHistorySize >= minSamples) {
                    g_hurstCenter = g_hurstSum / g_hurstHistorySize;
                    double variance = (g_hurstSumSq / g_hurstHistorySize) - (g_hurstCenter * g_hurstCenter);
                    g_hurstStdev = (variance > 0) ? MathSqrt(variance) : 0.0;
                    
                    // Aggiorna zona random e marca come pronto
                    if (g_hurstStdev > 0) {
                        double margin = g_hurstStdev * GetOrganicDecay(g_hurstCenter);
                        g_hurstRandomLow = g_hurstCenter - margin;
                        g_hurstRandomHigh = g_hurstCenter + margin;
                        g_hurstZoneReady = true;
                    }
                }
            }
        }
        
        // Salva in cache
        g_cachedResult_M5 = result_M5;
        g_cachedResult_H1 = result_H1;
        g_cachedResult_H4 = result_H4;
        g_cachedResult_D1 = result_D1;
        g_cacheValid = true;
        
        // FIX: Aggiorna prezzo e ATR per rilevamento gap successivo
        g_lastCachePrice = currentPrice;
        // Usa ATR medio dal TF piu' stabile disponibile
        if (g_dataReady_H1 && tfData_H1.atr_avg > 0) {
            g_lastCacheATR = tfData_H1.atr_avg;
        } else if (g_dataReady_H4 && tfData_H4.atr_avg > 0) {
            g_lastCacheATR = tfData_H4.atr_avg;
        } else if (g_dataReady_M5 && tfData_M5.atr_avg > 0) {
            g_lastCacheATR = tfData_M5.atr_avg;
        } else {
            // Fallback data-driven: periodo H1 x scale^2 pips * pointValue * scale(H)
            //    Usato SOLO se nessun TF ha ATR valido
            // Fallback = periodo H1 empirico x scale^2(H) ~= 48 pips
            int fallbackBase = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapSafeBars();
            int fallbackPips = GetDataDrivenBufferSize(fallbackBase, GetDefaultHurst(), 2);  // ~48 empirico
            g_lastCacheATR = g_pointValue * fallbackPips * GetOrganicScale(g_hurstGlobal);
        }
    } else {
        //  USA CACHE (molto pi veloce!)
        result_M5 = g_cachedResult_M5;
        result_H1 = g_cachedResult_H1;
        result_H4 = g_cachedResult_H4;
        result_D1 = g_cachedResult_D1;
    }
    
    // Aggiorna flag di validita'
    g_dataReady_M5 = result_M5.valid;
    g_dataReady_H1 = result_H1.valid;
    g_dataReady_H4 = result_H4.valid;
    g_dataReady_D1 = result_D1.valid;
    
    // Verifica che almeno un TF sia attivo
    if (!g_dataReady_M5 && !g_dataReady_H1 && !g_dataReady_H4 && !g_dataReady_D1) {
        Print("[RECALC] NESSUN TF HA DATI SUFFICIENTI");
        return;
    }
    
    // ---------------------------------------------------------------
    // STEP 2: RICALCOLA PESI EMPIRICI (Hurst)
    // peso_TF = hurstExponent_TF / somma(hurstExponent)
    // ---------------------------------------------------------------
    double totalHurst = 0;
    // hurstExponent validato nel range [HURST_RANGE_MIN, HURST_RANGE_MAX]
    if (result_M5.valid) totalHurst += result_M5.hurstExponent;
    if (result_H1.valid) totalHurst += result_H1.hurstExponent;
    if (result_H4.valid) totalHurst += result_H4.hurstExponent;
    if (result_D1.valid) totalHurst += result_D1.hurstExponent;
    
    // VALIDATO: Protezione divisione per zero
    if (totalHurst <= 0) totalHurst = GetDefaultHurst();  // Fallback empirico
    
    // VALIDATO: Pesi sempre >= 0 e normalizzati
    double weight_M5 = result_M5.valid ? (result_M5.hurstExponent / totalHurst) : 0;
    double weight_H1 = result_H1.valid ? (result_H1.hurstExponent / totalHurst) : 0;
    double weight_H4 = result_H4.valid ? (result_H4.hurstExponent / totalHurst) : 0;
    double weight_D1 = result_D1.valid ? (result_D1.hurstExponent / totalHurst) : 0;
    
    // ---------------------------------------------------------------
    // STEP 3: RICALCOLA PERIODI ORGANICI (solo se Hurst ricalcolato)
    // OTTIMIZZATO: salta se usiamo cache
    // ---------------------------------------------------------------
    if (needFullHurstRecalc) {
        if (g_dataReady_M5) CalculateOrganicPeriodsFromData(PERIOD_M5, g_organic_M5, result_M5.period, weight_M5, result_M5.hurstExponent);
        if (g_dataReady_H1) CalculateOrganicPeriodsFromData(PERIOD_H1, g_organic_H1, result_H1.period, weight_H1, result_H1.hurstExponent);
        if (g_dataReady_H4) CalculateOrganicPeriodsFromData(PERIOD_H4, g_organic_H4, result_H4.period, weight_H4, result_H4.hurstExponent);
        if (g_dataReady_D1) CalculateOrganicPeriodsFromData(PERIOD_D1, g_organic_D1, result_D1.period, weight_D1, result_D1.hurstExponent);
        
        // FIX: Controlla se i periodi sono cambiati significativamente (>25%)
        // Se si, ricrea gli handle indicatori con i nuovi periodi
        if (PeriodsChangedSignificantly()) {
            if (g_enableLogsEffective) {
                Print("[RECALC] Periodi cambiati >25% - Ricreazione handle indicatori...");
            }
            ReleaseIndicators();
            if (!InitializeIndicators()) {
                Print("[RECALC] Errore ricreazione handle indicatori!");
            } else {
                // FIX: Invalida cache dopo ricreazione handle - i dati vecchi non sono piu validi
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
    // STEP 4: AGGIORNA FILTRO HURST COMPLETO
    // - Regimi per ogni TF
    // - H PESATO (non media semplice!)
    // - Aggiunge H al buffer storico -> zona adattiva
    // - Calcola tradeScore e soglia
    // ---------------------------------------------------------------
    if (EnableHurstFilter) {
        g_hurstRegime_M5 = GetHurstRegime(result_M5.hurstExponent);
        g_hurstRegime_H1 = GetHurstRegime(result_H1.hurstExponent);
        g_hurstRegime_H4 = GetHurstRegime(result_H4.hurstExponent);
        g_hurstRegime_D1 = GetHurstRegime(result_D1.hurstExponent);
        
        // ---------------------------------------------------------------
        //  CALCOLO H PESATO (non media semplice!)
        // H_weighted = S(H_TF * peso_TF) / S(peso_TF)
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
        
        //  FIX CRITICO: Aggiunge H al buffer quando ricalcolato E weightSum > 0 (dati validi)
        // RIMOSSO check GetHurstMin/Max che impediva riempimento buffer iniziale
        // g_hurstComposite  gi validato dal range [HURST_RANGE_MIN, HURST_RANGE_MAX] in CalculateHurstExponent
        // DEBUG LIMITATO: stampa qualche volta anche in backtest per capire perch il buffer resta a 1/33
        static int dbgHurstAdds = 0;
        if (dbgHurstAdds < 20 && g_hurstHistorySize < 5) {
            PrintFormat("[HDEBUG] needFull=%s weightSum=%.2f g_cacheValid=%s dataReady=%d/%d/%d/%d valid=%s/%s/%s/%s H=%.4f size=%d/%d", 
                needFullHurstRecalc ? "TRUE" : "FALSE", weightSum, g_cacheValid ? "TRUE" : "FALSE",
                g_dataReady_M5, g_dataReady_H1, g_dataReady_H4, g_dataReady_D1,
                result_M5.valid ? "T" : "F", result_H1.valid ? "T" : "F", result_H4.valid ? "T" : "F", result_D1.valid ? "T" : "F",
                g_hurstComposite, g_hurstHistorySize, HURST_HISTORY_MAX);
            dbgHurstAdds++;
        }
        if (needFullHurstRecalc && weightSum > 0) {
            if (g_enableLogsEffective && g_hurstHistorySize < 5) {
                PrintFormat("[DEBUG] AddHurstToHistory: H=%.4f, Buffer=%d/%d, weightSum=%.2f", 
                    g_hurstComposite, g_hurstHistorySize, HURST_HISTORY_MAX, weightSum);
            }
            AddHurstToHistory(g_hurstComposite);
        }
        else if (g_enableLogsEffective && g_hurstHistorySize < 5) {
            PrintFormat("[DEBUG] AddHurstToHistory SKIP: needFullHurstRecalc=%s, weightSum=%.2f", 
                needFullHurstRecalc ? "TRUE" : "FALSE", weightSum);
        }
        
        // Calcola confidenza (usa g_hurstCenter calcolato in AddHurstToHistory)
        g_hurstConfidence = GetHurstConfidence(g_hurstComposite);
        
        // ---------------------------------------------------------------
        //  CALCOLA tradeScore 100% DAI DATI
        // deviation = |H - centro| dove centro = media(H) storica
        // normalizzazione = stdev storica * f (scala data-driven)
        // VALIDATO: tradeScore sempre >= 0
        //    - deviation >= 0 (MathAbs)
        //    - g_hurstConfidence in [0, 1] (validato in GetHurstConfidence)
        //    - normFactor > 0 quando usato
        // ---------------------------------------------------------------
        //  FIX: Check esplicito g_hurstStdev > 0 (pu essere 0 se tutti i valori Hurst sono identici)
        if (!g_hurstZoneReady) {
            g_hurstTradeScore = 0.0;  //  Zona non pronta  0 (sicuro)
        } else if (g_hurstStdev <= 0.001) {
            //  FIX: Se stdev  0, mercato molto stabile - PERMETTI trading!
            // Non abbiamo abbastanza variabilit per giudicare, quindi non bloccare
            g_hurstTradeScore = g_tradeScoreThreshold + 0.01;  // Sopra soglia = permetti
        } else {
            double deviation = MathAbs(g_hurstComposite - g_hurstCenter);  //  >= 0
            //  Normalizzazione: dividi per (stdev * scale(H)) - scala 100% dai dati
            double normFactor = g_hurstStdev * GetOrganicScale(g_hurstGlobal);
            if (normFactor > 0.001) {
                g_hurstTradeScore = deviation * g_hurstConfidence / normFactor;  //  >= 0
            } else {
                //  FIX: normFactor molto piccolo = permetti trading
                g_hurstTradeScore = g_tradeScoreThreshold + 0.01;
            }
        }
        
        //  Aggiorna buffer tradeScore per soglia adattiva
        //  FIX: RIEMPI SEMPRE - non aspettare g_hurstZoneReady
        //  OTTIMIZZATO: usa somme incrementali O(1) invece di O(n)
        //  FIX: Ricalcolo periodico anti-drift
        //  VALIDATO: g_hurstTradeScore >= 0 garantito (vedi sopra)
        {
            //  FIX: Ricalcolo completo periodico per evitare drift floating point
            //  SAFETY: Usa ArraySize() per dimensione reale
            int tradeScoreMax = ArraySize(g_tradeScoreHistory);
            if (tradeScoreMax <= 0) return;  // Safety check
            
            g_tradeScoreOperationCount++;
            if (g_tradeScoreOperationCount >= tradeScoreMax) {
                RecalculateTradeScoreSumsFromScratch();
                g_tradeScoreOperationCount = 0;
            }
            
            //  Sottrai valore vecchio se buffer pieno (PRIMA di sovrascrivere!)
            if (g_tradeScoreHistorySize == tradeScoreMax) {
                double oldValue = g_tradeScoreHistory[g_tradeScoreHistoryIndex];
                g_tradeScoreSum -= oldValue;
                g_tradeScoreSumSq -= oldValue * oldValue;
                
                //  SANITY CHECK: protezione da errori floating point accumulati
                if (g_tradeScoreSum < 0) g_tradeScoreSum = 0;
                if (g_tradeScoreSumSq < 0) g_tradeScoreSumSq = 0;
            }
            
            // Aggiungi nuovo valore
            g_tradeScoreHistory[g_tradeScoreHistoryIndex] = g_hurstTradeScore;
            g_tradeScoreSum += g_hurstTradeScore;
            g_tradeScoreSumSq += g_hurstTradeScore * g_hurstTradeScore;
            
            //  VALIDATO: indice buffer sempre nel range [0, arraySize-1]
            g_tradeScoreHistoryIndex = (g_tradeScoreHistoryIndex + 1) % tradeScoreMax;
            if (g_tradeScoreHistorySize < tradeScoreMax) g_tradeScoreHistorySize++;
        }
        
        //  Calcola soglia tradeScore O(1) con somme incrementali!
        // Minimo campioni = decay^2 del buffer (~25% per H=0.5, meno per H alto)
        double minFraction = GetOrganicDecayPow(g_hurstGlobal > 0 ? g_hurstGlobal : GetDefaultHurst(), 2.0);
        int minTradeScoreSamples = (int)MathCeil(TRADE_SCORE_HISTORY_MAX * minFraction);
        if (g_tradeScoreHistorySize >= minTradeScoreSamples) {
            //  VALIDATO: Media O(1) - divisione sicura (minTradeScoreSamples >= 1)
            double meanTS = g_tradeScoreSum / g_tradeScoreHistorySize;
            //  VALIDATO: Varianza O(1): E[X] - E[X] con protezione negativa
            double meanSqTS = g_tradeScoreSumSq / g_tradeScoreHistorySize;
            double varianceTS = meanSqTS - (meanTS * meanTS);
            double stdevTS = (varianceTS > 0) ? MathSqrt(varianceTS) : 0.0;
            double rawThreshold = meanTS + stdevTS * GetOrganicDecay(g_hurstGlobal);
            
            // FIX: Limita soglia massima per evitare blocco permanente
            // Soglia max = media + scale(H)stdev (adattivo al regime)
            double maxThreshold = meanTS + GetOrganicScale(g_hurstGlobal) * stdevTS;
            // Soglia min = media * decay (permetti almeno alcuni trade)
            double minThreshold = meanTS * GetOrganicDecay(g_hurstGlobal);
            g_tradeScoreThreshold = MathMax(minThreshold, MathMin(maxThreshold, rawThreshold));
            g_tradeScoreReady = true;
        } else {
            //  FIX: Con dati insufficienti, usa fallback invece di bloccare
            if (g_tradeScoreHistorySize > 0) {
                double meanTS = g_tradeScoreSum / g_tradeScoreHistorySize;
                g_tradeScoreThreshold = meanTS;  // Solo media, senza stdev
            } else {
                g_tradeScoreThreshold = 0;  // Permetti tutti i trade
            }
            g_tradeScoreReady = true;  //  FORZA READY per evitare blocco!
        }
        
        //  DECISIONE TRADE: richiede zona Hurst + soglia tradeScore pronte
        g_hurstReady = (g_hurstZoneReady && g_tradeScoreReady);
        g_hurstAllowTrade = g_hurstReady && (g_hurstTradeScore >= g_tradeScoreThreshold);
        
        //  LOG DIAGNOSTICO PERIODICO (anche in backtest) per debugging blocchi
        static int recalcCount = 0;
        recalcCount++;
        // Protezione overflow
        if (recalcCount > 1000000) recalcCount = 51;
        if (recalcCount == 1 || recalcCount == 10 || recalcCount % 50 == 0) {
            PrintFormat("[HURST DIAG #%d] H=%.3f Centro=%.3f Stdev=%.4f | TradeScore=%.4f %s Soglia=%.4f -> %s",
                recalcCount, g_hurstComposite, g_hurstCenter, g_hurstStdev,
                g_hurstTradeScore, 
                g_hurstTradeScore >= g_tradeScoreThreshold ? ">=" : "<",
                g_tradeScoreThreshold,
                g_hurstAllowTrade ? "TRADE OK" : "BLOCCATO");
        }
        
        lastHurstRecalc = TimeCurrent();
    }
    
    // ---------------------------------------------------------------
    //  STEP 5: AGGIORNA SOGLIA SCORE DINAMICA
    // Se AutoScoreThreshold=true, ricalcola dalla distribuzione
    // ---------------------------------------------------------------
    UpdateDynamicThreshold();
    
    // Log dettagliato del ricalcolo organico
    if (g_enableLogsEffective) {
        Print("+-----------------------------------------------------------------------------+");
        Print("|  RICALCOLO SISTEMA ORGANICO COMPLETATO                                    |");
        Print("+-----------------------------------------------------------------------------+");
        Print("| STEP 1: PERIODI NATURALI (derivati da autocorrelazione dati)               |");
        PrintFormat("|   M5=%3d | H1=%3d | H4=%3d | D1=%3d                                        |",
            result_M5.period, result_H1.period, result_H4.period, result_D1.period);
        Print("+-----------------------------------------------------------------------------+");
        Print("| STEP 2: ESPONENTI HURST (confronto vs g_hurstCenter storico)               |");
        PrintFormat("|   M5=%.3f(%s) H1=%.3f(%s) H4=%.3f(%s) D1=%.3f(%s)                       |",
            result_M5.hurstExponent, g_hurstRegime_M5 == HURST_TRENDING ? "TREND" : (g_hurstRegime_M5 == HURST_MEANREV ? "M-REV" : "RAND "),
            result_H1.hurstExponent, g_hurstRegime_H1 == HURST_TRENDING ? "TREND" : (g_hurstRegime_H1 == HURST_MEANREV ? "M-REV" : "RAND "),
            result_H4.hurstExponent, g_hurstRegime_H4 == HURST_TRENDING ? "TREND" : (g_hurstRegime_H4 == HURST_MEANREV ? "M-REV" : "RAND "),
            result_D1.hurstExponent, g_hurstRegime_D1 == HURST_TRENDING ? "TREND" : (g_hurstRegime_D1 == HURST_MEANREV ? "M-REV" : "RAND "));
        PrintFormat("|   H_pesato = %.4f (formula: S(H*peso) / S(peso))                          |", g_hurstComposite);
        Print("+-----------------------------------------------------------------------------+");
        Print("| STEP 3: PESI TF (derivati da Hurst: peso = H_TF / S(H))                     |");
        PrintFormat("|   M5=%.3f | H1=%.3f | H4=%.3f | D1=%.3f                                    |",
            weight_M5, weight_H1, weight_H4, weight_D1);
        Print("+-----------------------------------------------------------------------------|");
        Print("| STEP 4: ZONA HURST ADATTIVA (centro=mean(H), margine=stdev*decay)          |");
        PrintFormat("|   Centro: %.4f (mean storica) | Stdev: %.5f                              |", g_hurstCenter, g_hurstStdev);
        PrintFormat("|   Zona: [%.4f, %.4f] | Buffer: %d/%d campioni                              |",
            g_hurstRandomLow, g_hurstRandomHigh, g_hurstHistorySize, HURST_HISTORY_MAX);
        PrintFormat("|   TradeScore: %.4f | Soglia: %.4f | Stato: %s                               |",
            g_hurstTradeScore, g_tradeScoreThreshold,
            g_hurstAllowTrade ? "TRADE OK" : (g_hurstReady ? "BLOCCATO" : "ATTESA DATI"));
        Print("+-----------------------------------------------------------------------------|");
        Print("| STEP 5: SOGLIA SCORE DINAMICA (formula: mean + stdev * decay)              |");
        if (g_scoreThresholdReady) {
            PrintFormat("|   Soglia corrente: %.2f%% | Buffer: %d/%d | Pronta: SI                      |",
                g_dynamicThreshold, g_scoreHistorySize, SCORE_HISTORY_MAX);
        } else {
            PrintFormat("|   Soglia corrente: (in attesa dati) | Buffer: %d/%d | Pronta: NO           |",
                g_scoreHistorySize, SCORE_HISTORY_MAX);
        }
        Print("+-----------------------------------------------------------------------------+");
    }
}

//+------------------------------------------------------------------+
//|  Calcola ESPONENTE DI HURST (metodo R/S - OTTIMIZZATO)         |
//|  Scale derivate da periodi naturali  scale^n(H)               |
//+------------------------------------------------------------------+
double CalculateHurstExponent(MqlRates &rates[], int n)
{
    //  LIMITI DATA-DRIVEN: derivati da periodi naturali
    int minBarsHurst = GetBufferXLarge();    // ~128+ barre minimo
    //  MODIFICA: Non limitiamo pi il massimo - usa tutte le barre disponibili
    // Pi dati = calcolo H pi stabile e affidabile
    
    // DATA-DRIVEN: Range Hurst valido derivato da osservazioni empiriche
    double hurstMin = GetHurstMin();        // Minimo osservato + margine (o teorico se <10 obs)
    double hurstMax = GetHurstMax();        // Massimo osservato + margine (o teorico se <10 obs)
    
    // OTTIMIZZAZIONE: Minimo barre
    // Se dati insufficienti, ritorna centro storico SE disponibile dai DATI
    // NESSUN fallback teorico (0.5) - solo valori empirici!
    //  WARMUP ADATTIVO: se abbiamo meno barre del minimo ideale, usa tutto ci che  disponibile
    // purch sia >= 64 barre (minimo per R/S con almeno 2 scale valide)
    if (n < minBarsHurst) {
        minBarsHurst = MathMax(64, n);  //  Minimo 64 per calcolo H affidabile
    }

    if (n < 64) {  //  Se sotto il minimo assoluto, usa centro o default
        if (g_hurstZoneReady && g_hurstCenter > 0) return g_hurstCenter;
        return GetDefaultHurst();
    }
    
    //  MODIFICA: Usa TUTTE le barre disponibili (n) invece di limitare
    int effectiveN = n;
    
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
    //  METODO R/S - Scale derivate da periodi naturali EMPIRICI
    // Scale = periodo empirico  scale^n(H) per n = 0, 1, 2, 3, 4
    // Con H=0.5 e periodo~12: ~12, ~17, ~24, ~34, ~48 (distribuzione logaritmica)
    // ---------------------------------------------------------------
    double logN[5], logRS[5];
    //  Scale ottimizzate per R/S analysis: devono essere distribuite logaritmicamente
    // PROBLEMA: periodi naturali spesso troppo grandi (64+)  scale troppo grandi  numScales=0
    // SOLUZIONE: Usa scale fisse ottimizzate [8, 16] indipendentemente dai periodi naturali
    // Questo garantisce SEMPRE almeno 2-3 scale valide per numReturns ~255
    int scaleBaseMin = 8;   // Fisso ottimale per scale piccole
    int scaleBaseH1 = 16;   // Fisso ottimale per scale medie/grandi
    
    //  DEBUG: Log i valori base per diagnostica
    static int debugCount = 0;
    if (debugCount < 3) {  // Solo prime 3 volte per non riempire il log
        PrintFormat("[HURST DEBUG] n=%d effectiveN=%d numReturns=%d", n, effectiveN, numReturns);
        PrintFormat("[HURST DEBUG] scaleBaseMin=%d scaleBaseH1=%d g_hurstGlobal=%.3f", 
            scaleBaseMin, scaleBaseH1, g_hurstGlobal);
        debugCount++;
    }
    
    int scales[5];
    scales[0] = GetDataDrivenBufferSize(scaleBaseMin, g_hurstGlobal, 0);  // ~base
    scales[1] = GetDataDrivenBufferSize(scaleBaseMin, g_hurstGlobal, 1);  // ~base * 2^H
    scales[2] = GetDataDrivenBufferSize(scaleBaseH1, g_hurstGlobal, 0);   // ~H1
    scales[3] = GetDataDrivenBufferSize(scaleBaseH1, g_hurstGlobal, 1);   // ~H1 * 2^H
    scales[4] = GetDataDrivenBufferSize(scaleBaseH1, g_hurstGlobal, 2);   // ~H1 * 2^(2H)
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
    //  Minimo scale = 2 per accettare fasi bootstrap iniziali
    int minScales = 2;
    //  Se scale insufficienti, usa centro storico se disponibile, altrimenti Hurst default
    if (numScales < minScales) {
        PrintFormat("[HURST DEBUG]  Scale insufficienti: numScales=%d < %d (n=%d, effectiveN=%d)", 
            numScales, minScales, n, effectiveN);
        PrintFormat("[HURST DEBUG] Scales tentate: [%d, %d, %d, %d, %d]", 
            scales[0], scales[1], scales[2], scales[3], scales[4]);
        if (g_hurstZoneReady && g_hurstCenter > 0) return g_hurstCenter;
        return GetDefaultHurst();
    }
    
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
    for (int i = 0; i < numScales; i++) {
        sumX += logN[i];
        sumY += logRS[i];
        sumXY += logN[i] * logRS[i];
        sumX2 += logN[i] * logN[i];
    }
    
    double denom = numScales * sumX2 - sumX * sumX;
    //  Threshold divisione: 1e-5 (soglia numerica standard)
    double divThreshold = 1e-5;
    //  Se denominatore troppo piccolo, usa centro storico o Hurst default per non bloccare
    if (MathAbs(denom) < divThreshold) {
        if (g_hurstZoneReady && g_hurstCenter > 0) return g_hurstCenter;
        return GetDefaultHurst();
    }
    
    double H = (numScales * sumXY - sumX * sumY) / denom;
    
    // VALIDATO: Forza H nel range valido [HURST_RANGE_MIN, HURST_RANGE_MAX]
    // Range empirico tipico per mercati finanziari: [0.1, 0.9]
    H = MathMax(hurstMin, MathMin(hurstMax, H));
    return H;
}

//+------------------------------------------------------------------+
//| FILTRO HURST: Determina il regime da un singolo valore H         |
//| Soglie ADATTIVE 100% dai dati storici:                           |
//|   centro = media(H), margine = stdev(H) * decay(H)               |
//+------------------------------------------------------------------+
//  VALIDATO: Funzione robusta con protezioni
//    INPUT: h puo' essere qualsiasi valore
//    OUTPUT: ENUM valida garantita
ENUM_HURST_REGIME GetHurstRegime(double h)
{
    //  VALIDATO: Se H non valido o zona non pronta, ritorna stato sicuro
    if (h < 0 || !g_hurstZoneReady) return HURST_RANDOM;
    
    if (h > g_hurstRandomHigh) return HURST_TRENDING;   // Sopra zona random
    if (h < g_hurstRandomLow)  return HURST_MEANREV;    // Sotto zona random
    return HURST_RANDOM;                                 // Dentro zona random
}

//+------------------------------------------------------------------+
//| FILTRO HURST: Calcola confidenza                                 |
//| Confidenza = |H - centro| / (stdev * f), capped a 1.0            |
//| Tutto derivato dai dati: centro = media(H), scala = stdev         |
//| VALIDATO:                                                        |
//|    INPUT: h puo' essere qualsiasi valore                          |
//|    OUTPUT: valore nel range [0.0, 1.0] garantito                  |
//+------------------------------------------------------------------+
double GetHurstConfidence(double h)
{
    //  VALIDATO: Se non pronto o stdev invalido, ritorna 0.0 (sicuro)
    if (!g_hurstZoneReady || g_hurstStdev <= 0) return 0.0;
    double deviation = MathAbs(h - g_hurstCenter);
    double maxDeviation = g_hurstStdev * GetOrganicScale(g_hurstGlobal);  // Scala basata su stdev * scale(H)
    //  VALIDATO: maxDeviation > 0 perch stdev > 0 e scale(H) > 0
    double confidence = deviation / maxDeviation;
    return MathMin(1.0, confidence);               //  Cap a 1.0
}

//+------------------------------------------------------------------+
//| FILTRO HURST: Inizializza buffer H storico                        |
//| NESSUN VALORE INIZIALE - tutto sara' calcolato dai dati!          |
//| VALIDAZIONE: Tutti i valori inizializzati a stati sicuri          |
//+------------------------------------------------------------------+
void InitHurstHistoryBuffer()
{
    // VALIDATO: Buffer dimensionato correttamente
    ArrayResize(g_hurstHistory, HURST_HISTORY_MAX);
    ArrayInitialize(g_hurstHistory, 0);  // Vuoto, verra' riempito dai dati
    
    // VALIDATO: Indici inizializzati a 0 (stato sicuro)
    g_hurstHistorySize = 0;
    g_hurstHistoryIndex = 0;
    
    // VALIDATO: Statistiche inizializzate a 0 (stato "non calcolato")
    g_hurstCenter = 0.0;
    g_hurstStdev = 0.0;
    g_hurstZoneMargin = 0.0;
    g_hurstRandomLow = 0.0;
    g_hurstRandomHigh = 0.0;
    g_hurstZoneReady = false;  // Flag indica che i dati NON sono pronti
    
    // VALIDATO: Somme incrementali a 0 (coerente con buffer vuoto)
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
        PrintFormat("[INIT-BUFFER] g_hurstHistory: ArraySize=%d (max=%d) %s",
            ArraySize(g_hurstHistory), HURST_HISTORY_MAX,
            ArraySize(g_hurstHistory) == HURST_HISTORY_MAX ? "OK" : "WARN");
        PrintFormat("[INIT-BUFFER] g_tradeScoreHistory: ArraySize=%d (max=%d) %s",
            ArraySize(g_tradeScoreHistory), TRADE_SCORE_HISTORY_MAX,
            ArraySize(g_tradeScoreHistory) == TRADE_SCORE_HISTORY_MAX ? "OK" : "WARN");
    }
}

//+------------------------------------------------------------------+
//|  PRE-CARICAMENTO MULTI-TF OTTIMIZZATO                          |
//| Usa tutti i TF disponibili ma con campionamento per velocit     |
//+------------------------------------------------------------------+
void PreloadHurstBufferFromHistory()
{
    if (!EnableHurstFilter) return;
    
    //  TIMER: Misura tempo totale preload
    uint startTime = GetTickCount();
    
    //  CONFIGURAZIONE 100% DATA-DRIVEN
    //  PRELOAD VELOCE: usa 64 barre invece di GetBufferXLarge() per performance
    // Il preload serve solo per bootstrap, non serve precisione massima
    int barsPerHurst = 64;  //  RIDOTTO da 128 a 64 per velocizzare preload 4
    int samplesToPreload = HURST_HISTORY_MAX;  // Calcolato dinamicamente in OnInit
    //  OTTIMIZZAZIONE PERFORMANCE: skipFactor = 4 invece di 2 per velocizzare preload 2
    // Riduce campioni da 32 a 16, dimezza tempo preload (~60 sec  ~30 sec)
    int skipFactor = MathMax(4, (int)MathCeil(GetOrganicScale(g_hurstGlobal) * 2.0));
    int effectiveSamples = samplesToPreload / skipFactor;
    
    //  Buffer: tutti derivati da periodi naturali
    int bufferM5 = GetBufferMedium();  // ~17
    int bufferH1 = GetBufferSmall();   // ~12
    // Buffer H4 = periodo H4 empirico (H4 per giorno)
    int bufferH4Base = (g_naturalPeriod_H4 > 0) ? g_naturalPeriod_H4 : BOOTSTRAP_MIN_BARS;
    int bufferH4 = MathMax(4, bufferH4Base);
    int bufferD1 = GetBufferMedium();  // ~17
    
    //  Rapporti TF calcolati dinamicamente dai minuti reali
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
    // Divisori derivati da scale (data-driven): H1 = scale, H4 = scale
    double scaleH = GetOrganicScale(g_hurstGlobal);  // scale(H)  1.4-2.0
    double scale2H = GetOrganicScalePow(g_hurstGlobal, 2.0);  // scale(H)  2.0-4.0
    int totalBarsH1 = (int)MathRound(totalBarsM5 / ratioH1) + (int)MathRound(barsPerHurst / scaleH) + bufferH1;
    int totalBarsH4 = (int)MathRound(totalBarsM5 / ratioH4) + (int)MathRound(barsPerHurst / scale2H) + bufferH4;
    int totalBarsD1 = (int)MathRound(totalBarsM5 / ratioD1) + bufferD1;
    
    // Carica dati per tutti i TF disponibili
    MqlRates ratesM5[], ratesH1[], ratesH4[], ratesD1[];
    ArraySetAsSeries(ratesM5, true);
    ArraySetAsSeries(ratesH1, true);
    ArraySetAsSeries(ratesH4, true);
    ArraySetAsSeries(ratesD1, true);
    
    //  FIX: Usa start=1 per caricare dati STORICI (barre completate, non quella corrente incompleta)
    int copiedM5 = g_dataReady_M5 ? CopyRates(_Symbol, PERIOD_M5, 1, totalBarsM5, ratesM5) : 0;
    int copiedH1 = g_dataReady_H1 ? CopyRates(_Symbol, PERIOD_H1, 1, totalBarsH1, ratesH1) : 0;
    int copiedH4 = g_dataReady_H4 ? CopyRates(_Symbol, PERIOD_H4, 1, totalBarsH4, ratesH4) : 0;
    int copiedD1 = g_dataReady_D1 ? CopyRates(_Symbol, PERIOD_D1, 1, totalBarsD1, ratesD1) : 0;
    
    if (copiedM5 < barsPerHurst) {
        Print("[PRELOAD] Dati M5 insufficienti per pre-caricamento");
        return;
    }
    
    Print("[PRELOAD] Pre-caricamento MULTI-TF ottimizzato...");
    PrintFormat("[PRELOAD] Barre: M5=%d H1=%d H4=%d D1=%d | Campioni=%d (skip=%d)",
        copiedM5, copiedH1, copiedH4, copiedD1, effectiveSamples, skipFactor);
    
    // ---------------------------------------------------------------
    // FASE 1: Calcola Hurst composito campionato
    //  VALIDATO: Ogni hX validato nel range organico prima di usare
    //  FIX STACK OVERFLOW: Alloca array riutilizzabili FUORI dal loop
    // ---------------------------------------------------------------
    double hurstValues[];
    ArrayResize(hurstValues, effectiveSamples);
    ArrayInitialize(hurstValues, 0);
    int successCount = 0;
    int lastValidIndex = -1;
    
    //  ANTI-STACK-OVERFLOW: Alloca UNA VOLTA tutti gli array necessari
    // Riutilizzali nel loop invece di creare nuovi array ogni iterazione
    MqlRates subRatesM5[], subRatesH1[], subRatesH4[], subRatesD1[];
    int maxBarsNeeded = 128;  //  FISSO a 128 per sicurezza (era barsPerHurst*2)
    ArrayResize(subRatesM5, maxBarsNeeded);
    ArrayResize(subRatesH1, maxBarsNeeded);
    ArrayResize(subRatesH4, maxBarsNeeded);
    ArrayResize(subRatesD1, maxBarsNeeded);
    
    for (int sample = 0; sample < effectiveSamples; sample++) {
        //  PROGRESS: Print ogni 8 campioni per dare feedback
        if (sample % 8 == 0 || sample == effectiveSamples - 1) {
            PrintFormat("[PRELOAD] Progresso: %d/%d campioni (%.0f%%)...", 
                sample + 1, effectiveSamples, 100.0 * (sample + 1) / effectiveSamples);
        }
        
        int i = sample * skipFactor;
        double hurstWeightedSum = 0;
        double weightSum = 0;
        
        // M5 -  VALIDATO: hM5 controllato nel range organico
        if (copiedM5 >= i + barsPerHurst) {
            //  RIUSA array pre-allocato invece di creare nuovo
            for (int j = 0; j < barsPerHurst; j++) subRatesM5[j] = ratesM5[i + j];
            double hM5 = CalculateHurstExponent(subRatesM5, barsPerHurst);
            //  FIX: RIMOSSO check min/max - accettiamo tutti i valori Hurst validi
            if (hM5 > 0 && hM5 < 1.0) {
                UpdateHurstLimits(hM5);  // Aggiorna limiti empirici
                hurstWeightedSum += hM5 * g_organic_M5.weight;
                weightSum += g_organic_M5.weight;
            }
        }
        
        // H1 -  VALIDATO: hH1 controllato nel range organico
        if (copiedH1 > 0) {
            //  Rapporto calcolato dinamicamente
            int idxH1 = (int)MathRound(i / ratioH1);
            double scaleH = GetOrganicScale(g_hurstGlobal); // Divisore empirico
            int barsH1 = MathMin(64, (int)MathRound(barsPerHurst / scaleH));  //  MAX 64
            if (copiedH1 >= idxH1 + barsH1) {
                //  RIUSA array pre-allocato
                for (int j = 0; j < barsH1; j++) subRatesH1[j] = ratesH1[idxH1 + j];
                double hH1 = CalculateHurstExponent(subRatesH1, barsH1);
                //  FIX: RIMOSSO check min/max - accettiamo tutti i valori Hurst validi
                if (hH1 > 0 && hH1 < 1.0) {
                    UpdateHurstLimits(hH1);  // Aggiorna limiti empirici
                    hurstWeightedSum += hH1 * g_organic_H1.weight;
                    weightSum += g_organic_H1.weight;
                }
            }
        }
        
        // H4 -  VALIDATO: hH4 controllato nel range organico
        if (copiedH4 > 0) {
            //  Rapporto calcolato dinamicamente
            int idxH4 = (int)MathRound(i / ratioH4);
            double scale2H = GetOrganicScalePow(g_hurstGlobal, 2.0); // Divisore empirico
            int barsH4 = MathMin(64, (int)MathRound(barsPerHurst / scale2H));  //  MAX 64
            if (copiedH4 >= idxH4 + barsH4) {
                //  RIUSA array pre-allocato
                for (int j = 0; j < barsH4; j++) subRatesH4[j] = ratesH4[idxH4 + j];
                double hH4 = CalculateHurstExponent(subRatesH4, barsH4);
                //  FIX: RIMOSSO check min/max - accettiamo tutti i valori Hurst validi
                if (hH4 > 0 && hH4 < 1.0) {
                    UpdateHurstLimits(hH4);  // Aggiorna limiti empirici
                    hurstWeightedSum += hH4 * g_organic_H4.weight;
                    weightSum += g_organic_H4.weight;
                }
            }
        }
        
        // D1 -  VALIDATO: hD1 controllato nel range organico
        //  Minimo barre D1 = 16 (potenza di 2)
        int minBarsD1 = GetBufferMedium();  // 16
        if (copiedD1 >= minBarsD1) {
            //  Rapporto calcolato dinamicamente
            int idxD1 = (int)MathRound(i / ratioD1);
            //  Buffer D1 = 8 (potenza di 2)
            int bufD1 = GetBufferSmall();  // 8
            if (idxD1 < copiedD1 - bufD1) {
                //  LIMITA a 64 barre per performance preload
                int barsD1 = MathMin(64, copiedD1 - idxD1);  //  MAX 64 per velocit
                //  RIUSA array pre-allocato
                for (int j = 0; j < barsD1; j++) subRatesD1[j] = ratesD1[idxD1 + j];
                double hD1 = CalculateHurstExponent(subRatesD1, barsD1);
                //  FIX: RIMOSSO check min/max - accettiamo tutti i valori Hurst validi
                if (hD1 > 0 && hD1 < 1.0) {
                    UpdateHurstLimits(hD1);  // Aggiorna limiti empirici
                    hurstWeightedSum += hD1 * g_organic_D1.weight;
                    weightSum += g_organic_D1.weight;
                }
            }
        }
        
        // Calcola Hurst composito pesato
        // VALIDATO: weightSum > 0, hComposite nel range organico
        if (weightSum > 0) {
            double hComposite = hurstWeightedSum / weightSum;
            
            //  FIX: RIMOSSO check min/max che bloccava preload iniziale
            // Il range Hurst  DERIVATO dai dati, non imposto a priori!
            // I valori Hurst sono gi validati in CalculateHurstExponent
            
            hurstValues[sample] = hComposite;
            lastValidIndex = sample;
            
            //  SAFETY: Usa ArraySize() per dimensione reale
            int hurstMax = ArraySize(g_hurstHistory);
            if (hurstMax <= 0) return;  // Safety check
            
            // Sliding window: Se buffer troppo vicino al limite, cleanup
            // Soglia = 1 - decay(H) = persistenza alta (~0.7 per H=0.5)
            double cleanupThreshold = 1.0 - GetOrganicDecay(GetDefaultHurst());
            if (g_hurstHistorySize >= hurstMax * cleanupThreshold) {
                CleanupHistoryBuffer(g_hurstHistory, g_hurstHistorySize, g_hurstHistoryIndex, 
                                     g_hurstSum, g_hurstSumSq);
                hurstMax = ArraySize(g_hurstHistory);  // Aggiorna dopo resize
            }
            
            // Aggiungi al buffer (replica per compensare skip)
            //  CRITICO: Aggiorna anche le somme incrementali!
            for (int rep = 0; rep < skipFactor; rep++) {
                //  Se buffer pieno, sottrai valore vecchio che stiamo per sovrascrivere
                if (g_hurstHistorySize == hurstMax) {
                    double oldValue = g_hurstHistory[g_hurstHistoryIndex];
                    g_hurstSum -= oldValue;
                    g_hurstSumSq -= oldValue * oldValue;
                    
                    //  SANITY CHECK: protezione da errori floating point
                    if (g_hurstSum < 0) g_hurstSum = 0;
                    if (g_hurstSumSq < 0) g_hurstSumSq = 0;
                }
                
                g_hurstHistory[g_hurstHistoryIndex] = hComposite;  //  Valore gi validato
                g_hurstSum += hComposite;
                g_hurstSumSq += hComposite * hComposite;
                //  VALIDATO: indice sempre nel range [0, arraySize-1]
                g_hurstHistoryIndex = (g_hurstHistoryIndex + 1) % hurstMax;
                
                if (g_hurstHistorySize < hurstMax) {
                    g_hurstHistorySize++;
                }
            }
            successCount++;
        }
    }
    
    //  FASE 1 COMPLETATA
    PrintFormat("[PRELOAD] FASE 1 completata: %d/%d campioni Hurst validi", successCount, effectiveSamples);
    
    // ---------------------------------------------------------------
    // FASE 2: Calcola centro, stdev e zona Hurst
    //  OTTIMIZZATO: usa le somme incrementali gia' calcolate!
    //  VALIDATO: divisione sicura (g_hurstHistorySize >= minSamples >= 1)
    //  FIX: Check esplicito per g_hurstHistorySize == 0
    // ---------------------------------------------------------------
    
    // FIX: Protezione divisione per zero - nessun campione valido
    if (g_hurstHistorySize == 0) {
        //  FALLBACK DATA-DRIVEN: Centro = (min+max)/2 dai limiti empirici
        g_hurstCenter = (GetHurstMin() + GetHurstMax()) / 2.0;  // Centro range osservato
        // Stdev stimato da range empirico (o teorico se <10 obs)
        g_hurstStdev = (GetHurstMax() - GetHurstMin()) / 4.0;  // Range/4  1 per distribuzione uniforme
        g_hurstZoneMargin = g_hurstStdev * GetOrganicDecay(GetDefaultHurst());
        g_hurstRandomLow = g_hurstCenter - g_hurstZoneMargin;
        g_hurstRandomHigh = g_hurstCenter + g_hurstZoneMargin;
        g_hurstZoneReady = true;  //  FORZA READY con fallback
        PrintFormat("[PRELOAD] Nessun campione Hurst valido - FALLBACK centro=%.2f zona=[%.2f, %.2f]", 
            g_hurstCenter, g_hurstRandomLow, g_hurstRandomHigh);
        // Continua comunque per calcolare TradeScore
    }
    
    // Minimo campioni = decay^2 del buffer (~25% per H=0.5)
    double minFractionPreload = GetOrganicDecayPow(GetDefaultHurst(), 2.0);
    int minSamples = (int)MathCeil(HURST_HISTORY_MAX * minFractionPreload);
    if (g_hurstHistorySize > 0 && g_hurstHistorySize < minSamples) {
        //  FIX: Anche con dati parziali, calcola comunque zona (non bloccare!)
        PrintFormat("[PRELOAD] Pre-caricamento parziale Hurst: %d/%d campioni - calcolo comunque", 
            successCount, minSamples);
        // Continua invece di return!
    }
    
    //   Calcola centro O(1) - divisione sicura (g_hurstHistorySize > 0 garantito dopo fallback)
    if (g_hurstHistorySize > 0) {
        g_hurstCenter = g_hurstSum / g_hurstHistorySize;
        
        //   Calcola stdev O(1): Var(X) = E[X] - E[X] con protezione negativa
        double meanSq = g_hurstSumSq / g_hurstHistorySize;
        double variance = meanSq - (g_hurstCenter * g_hurstCenter);
        g_hurstStdev = (variance > 0) ? MathSqrt(variance) : 0.0;  //  >= 0
        
        // Calcola margine e zona usando decay dinamico
        double globalDecay = GetOrganicDecay(g_hurstGlobal);
        double globalScale = GetOrganicScale(g_hurstGlobal);  // 2^H
        double newMargin = g_hurstStdev * globalDecay;
        double minMargin = g_hurstStdev * globalDecay * globalDecay;  // decay^2 ~ 0.25
        double maxMargin = g_hurstStdev * globalScale;  // scale(H) ~ 1.4-1.6
        g_hurstZoneMargin = MathMax(minMargin, MathMin(maxMargin, newMargin));  //  >= 0
        
        g_hurstRandomLow = g_hurstCenter - g_hurstZoneMargin;
        g_hurstRandomHigh = g_hurstCenter + g_hurstZoneMargin;
        g_hurstZoneReady = true;
        
        PrintFormat("[PRELOAD] Buffer Hurst: %d/%d | Centro=%.4f Stdev=%.4f Zona=[%.4f, %.4f]", 
            successCount, samplesToPreload, g_hurstCenter, g_hurstStdev, g_hurstRandomLow, g_hurstRandomHigh);
    }
    // Se g_hurstHistorySize == 0, il fallback  gi stato impostato sopra
    
    // Variabili per FASE 3 - usa fallback se non calcolate
    double globalDecay = GetOrganicDecay(g_hurstGlobal);
    double globalScale = GetOrganicScale(g_hurstGlobal);
    
    // ---------------------------------------------------------------
    // FASE 3: Calcola TradeScore per ogni campione Hurst e riempi buffer
    // Ora che abbiamo centro e stdev, possiamo calcolare i tradeScore!
    //  VALIDATO: tradeScore >= 0 garantito
    // ---------------------------------------------------------------
    PrintFormat("[PRELOAD] FASE 3: Calcolo TradeScore su %d campioni...", effectiveSamples);
    int tradeScoreCount = 0;
    int samplesToPreloadTS = MathMin(effectiveSamples, TRADE_SCORE_HISTORY_MAX);
    
    for (int i = 0; i < samplesToPreloadTS; i++) {
        double h = hurstValues[i];
        //  FIX: RIMOSSO check min/max - accettiamo tutti i valori Hurst
        if (h <= 0) continue;  // Solo check per valori invalidi
        
        //  Calcola confidence (stessa logica di GetHurstConfidence)
        double deviation = MathAbs(h - g_hurstCenter);  //  >= 0
        double maxDeviation = g_hurstStdev * globalScale;  // scale(H) sigma
        double confidence = (maxDeviation > 0) ? MathMin(1.0, deviation / maxDeviation) : 0.0;  //  [0, 1]
        
        //  Calcola tradeScore (stessa logica di RecalculateOrganicSystem)
        double normFactor = g_hurstStdev * globalScale;  // scale(H) sigma
        double tradeScore = 0;
        if (normFactor > 0) {
            tradeScore = deviation * confidence / normFactor;  //  >= 0
        }
        
        //  SAFETY: Usa ArraySize() per dimensione reale
        int tradeScoreMax = ArraySize(g_tradeScoreHistory);
        if (tradeScoreMax <= 0) continue;  // Safety check
        
        // Sliding window: Se buffer troppo vicino al limite, cleanup
        double cleanupThreshold = 1.0 - GetOrganicDecay(GetDefaultHurst());
        if (g_tradeScoreHistorySize >= tradeScoreMax * cleanupThreshold) {
            CleanupHistoryBuffer(g_tradeScoreHistory, g_tradeScoreHistorySize, g_tradeScoreHistoryIndex,
                                 g_tradeScoreSum, g_tradeScoreSumSq);
            tradeScoreMax = ArraySize(g_tradeScoreHistory);  // Aggiorna dopo resize
        }
        
        // Aggiungi al buffer TradeScore
        //  CRITICO: Aggiorna anche le somme incrementali!
        //  Se buffer pieno, sottrai valore vecchio che stiamo per sovrascrivere
        if (g_tradeScoreHistorySize == tradeScoreMax) {
            double oldValue = g_tradeScoreHistory[g_tradeScoreHistoryIndex];
            g_tradeScoreSum -= oldValue;
            g_tradeScoreSumSq -= oldValue * oldValue;
            
            //  SANITY CHECK: protezione da errori floating point
            if (g_tradeScoreSum < 0) g_tradeScoreSum = 0;
            if (g_tradeScoreSumSq < 0) g_tradeScoreSumSq = 0;
        }
        
        g_tradeScoreHistory[g_tradeScoreHistoryIndex] = tradeScore;
        g_tradeScoreSum += tradeScore;
        g_tradeScoreSumSq += tradeScore * tradeScore;
        //  VALIDATO: indice sempre nel range [0, arraySize-1]
        g_tradeScoreHistoryIndex = (g_tradeScoreHistoryIndex + 1) % tradeScoreMax;
        
        if (g_tradeScoreHistorySize < tradeScoreMax) {
            g_tradeScoreHistorySize++;
        }
        tradeScoreCount++;
    }
    
    // ---------------------------------------------------------------
    // FASE 4: Calcola soglia TradeScore dai dati pre-caricati
    // OTTIMIZZATO: usa le somme incrementali gi calcolate!
    // VALIDATO: divisione sicura (minTradeScoreSamples >= 1)
    // ---------------------------------------------------------------
    double minFractionTS = GetOrganicDecayPow(GetDefaultHurst(), 2.0);
    int minTradeScoreSamples = (int)MathCeil(TRADE_SCORE_HISTORY_MAX * minFractionTS);
    if (g_tradeScoreHistorySize >= minTradeScoreSamples) {
        //   Media O(1) - divisione sicura
        double meanTS = g_tradeScoreSum / g_tradeScoreHistorySize;
        
        //   Varianza O(1): Var(X) = E[X] - E[X] con protezione negativa
        double meanSqTS = g_tradeScoreSumSq / g_tradeScoreHistorySize;
        double varianceTS = meanSqTS - (meanTS * meanTS);
        double stdevTS = (varianceTS > 0) ? MathSqrt(varianceTS) : 0.0;
        
        double rawThreshold = meanTS + stdevTS * GetOrganicDecay(g_hurstGlobal);
        //  FIX: Limita soglia massima per evitare blocco permanente
        double maxThreshold = meanTS + 2.0 * stdevTS;
        double minThreshold = meanTS * GetOrganicDecay(g_hurstGlobal);
        g_tradeScoreThreshold = MathMax(minThreshold, MathMin(maxThreshold, rawThreshold));
        g_tradeScoreReady = true;
        
        PrintFormat("[PRELOAD] Buffer TradeScore: %d/%d | Soglia=%.4f (range: %.4f-%.4f)", 
            tradeScoreCount, TRADE_SCORE_HISTORY_MAX, g_tradeScoreThreshold, minThreshold, maxThreshold);
    } else {
        //  FIX: Se non abbiamo abbastanza campioni, usa FALLBACK per permettere trading!
        // Soglia fallback = 0 (permetti tutti i trade finch non abbiamo dati)
        // Questo evita il blocco permanente del warm-up
        if (tradeScoreCount > 0) {
            double meanTS = g_tradeScoreSum / g_tradeScoreHistorySize;
            g_tradeScoreThreshold = meanTS;  // Usa solo media, senza stdev
        } else {
            g_tradeScoreThreshold = 0;  // Permetti tutti i trade
        }
        g_tradeScoreReady = true;  //  FORZA READY per evitare blocco!
        PrintFormat("[PRELOAD] TradeScore parziale: %d campioni - FALLBACK soglia=%.4f (trading permesso)", 
            tradeScoreCount, g_tradeScoreThreshold);
    }
    
    // ---------------------------------------------------------------
    // FASE 5: Imposta stato globale per permettere trading immediato
    // CRITICO: Calcola g_hurstTradeScore e g_hurstAllowTrade!
    //  VALIDATO: tutti i valori usati sono gia' validati nelle fasi precedenti
    // ---------------------------------------------------------------
    g_hurstReady = (g_hurstZoneReady && g_tradeScoreReady);
    
    if (g_hurstReady) {
        //  FIX: Gestisci anche caso fallback (lastValidIndex < 0)
        double lastHurst;
        if (lastValidIndex >= 0) {
            // Usa l'ultimo Hurst valido (il pi recente, tracciato da lastValidIndex)
            lastHurst = hurstValues[lastValidIndex];  //  Gi validato nel range organico
        } else {
            // FALLBACK: Usa centro Hurst (gi impostato dal fallback sopra)
            lastHurst = g_hurstCenter;
        }
        g_hurstComposite = lastHurst;
        
        //  Calcola g_hurstConfidence (stessa logica di GetHurstConfidence)
        double deviation = MathAbs(lastHurst - g_hurstCenter);  //  >= 0
        double maxDeviation = g_hurstStdev * GetOrganicScale(g_hurstGlobal);
        g_hurstConfidence = (maxDeviation > 0) ? MathMin(1.0, deviation / maxDeviation) : 0.0;  //  [0, 1]
        
        //  Calcola g_hurstTradeScore (stessa logica di RecalculateOrganicSystem)
        double normFactor = g_hurstStdev * GetOrganicScale(g_hurstGlobal);
        if (normFactor > 0) {
            g_hurstTradeScore = deviation * g_hurstConfidence / normFactor;  //  >= 0
        } else {
            //  FALLBACK: Se normFactor == 0, permetti il trade (non bloccare)
            g_hurstTradeScore = g_tradeScoreThreshold;  // Esattamente uguale = permesso
        }
        
        // CRITICO: Setta g_hurstAllowTrade per permettere trading!
        g_hurstAllowTrade = (g_hurstTradeScore >= g_tradeScoreThreshold);
        
        //  TEMPO TOTALE
        uint endTime = GetTickCount();
        double elapsedSeconds = (endTime - startTime) / 1000.0;
        
        PrintFormat("[PRELOAD] PRE-CARICAMENTO COMPLETO! Tempo: %.1f secondi", elapsedSeconds);
        PrintFormat("[PRELOAD]   H_composito=%.4f | Centro=%.4f | Confidence=%.3f", 
            g_hurstComposite, g_hurstCenter, g_hurstConfidence);
        PrintFormat("[PRELOAD]   TradeScore=%.4f %s Soglia=%.4f -> %s", 
            g_hurstTradeScore, 
            g_hurstTradeScore >= g_tradeScoreThreshold ? ">=" : "<",
            g_tradeScoreThreshold,
            g_hurstAllowTrade ? "TRADE OK" : "BLOCCATO");
    } else {
        //  FALLBACK FINALE: Se tutto fallisce, permetti comunque il trading
        // Questo evita che l'EA rimanga bloccato per sempre
        g_hurstAllowTrade = true;
        g_hurstTradeScore = 0;
        g_tradeScoreThreshold = 0;
        Print("[PRELOAD] Pre-caricamento fallito - FALLBACK: trading permesso con filtro Hurst disabilitato");
    }
}

//+------------------------------------------------------------------+
//| FILTRO HURST: Aggiungi H al buffer e aggiorna zona adattiva      |
//| OTTIMIZZATO: Usa somme incrementali O(1) invece di O(n)          |
//| FIX: Ricalcolo periodico completo per evitare drift numerico     |
//| INPUT VALIDATO: h deve essere nel range [HURST_RANGE_MIN, MAX]   |
//|    (validazione fatta dal chiamante prima di questa funzione)    |
//+------------------------------------------------------------------+
void AddHurstToHistory(double h)
{
    //  SAFETY: Usa ArraySize() per dimensione reale
    int hurstMax = ArraySize(g_hurstHistory);
    if (hurstMax <= 0) return;  // Safety check
    
    //  FIX: Ricalcolo completo periodico per evitare drift floating point
    // Ogni hurstMax operazioni, ricalcola somme da zero
    g_hurstOperationCount++;
    if (g_hurstOperationCount >= hurstMax) {
        RecalculateHurstSumsFromScratch();
        g_hurstOperationCount = 0;
    }
    
    //  VALIDATO: Sottrai valore vecchio se buffer pieno (buffer circolare)
    if (g_hurstHistorySize == hurstMax) {
        double oldValue = g_hurstHistory[g_hurstHistoryIndex];
        g_hurstSum -= oldValue;
        g_hurstSumSq -= oldValue * oldValue;
        
        //  SANITY CHECK: protezione da errori floating point accumulati
        if (g_hurstSum < 0) g_hurstSum = 0;
        if (g_hurstSumSq < 0) g_hurstSumSq = 0;
    }
    
    //  VALIDATO: Aggiungi nuovo valore al buffer
    g_hurstHistory[g_hurstHistoryIndex] = h;
    g_hurstSum += h;
    g_hurstSumSq += h * h;
    
    //  VALIDATO: Indice sempre nel range [0, arraySize-1] grazie al modulo
    g_hurstHistoryIndex = (g_hurstHistoryIndex + 1) % hurstMax;
    
    //  VALIDATO: Size mai > arraySize
    if (g_hurstHistorySize < hurstMax) {
        g_hurstHistorySize++;
        if (g_enableLogsEffective && g_hurstHistorySize <= 5) {
            PrintFormat("[DEBUG] Buffer Hurst incrementato: %d/%d (H=%.4f)", 
                g_hurstHistorySize, hurstMax, h);
        }
    }
    
    // Ricalcola CENTRO e STDEV con somme incrementali O(1)!
    double minFractionH = GetOrganicDecayPow(g_hurstGlobal > 0 ? g_hurstGlobal : GetDefaultHurst(), 2.0);
    int minSamples = (int)MathCeil(HURST_HISTORY_MAX * minFractionH);
    if (g_hurstHistorySize >= minSamples) {
        //  VALIDATO: Divisione sicura (minSamples >= 1)
        g_hurstCenter = g_hurstSum / g_hurstHistorySize;
        
        //  VALIDATO: Varianza O(1) con protezione per valori negativi
        double meanSq = g_hurstSumSq / g_hurstHistorySize;
        double variance = meanSq - (g_hurstCenter * g_hurstCenter);
        g_hurstStdev = (variance > 0) ? MathSqrt(variance) : 0.0;
        
        //  Aggiorna Hurst globale
        UpdateGlobalHurst();
        
        // MARGINE = stdev x decay (dinamico)
        double globalDecay = GetOrganicDecay(g_hurstGlobal);
        double globalScale = GetOrganicScale(g_hurstGlobal);  // 2^H
        double newMargin = g_hurstStdev * globalDecay;
        double minMargin = g_hurstStdev * globalDecay * globalDecay;  // decay^2 ~ 0.25
        double maxMargin = g_hurstStdev * globalScale;  // scale(H) invece di 2.0 fisso
        g_hurstZoneMargin = MathMax(minMargin, MathMin(maxMargin, newMargin));
        
        //  ZONA = centro  margine
        g_hurstRandomLow = g_hurstCenter - g_hurstZoneMargin;
        g_hurstRandomHigh = g_hurstCenter + g_hurstZoneMargin;
        g_hurstZoneReady = true;  //  Flag: dati pronti per l'uso
    }
    else {
        g_hurstZoneReady = false;  //  Flag: dati NON pronti
    }
}

//+------------------------------------------------------------------+
//| FIX: Ricalcolo completo somme Hurst per evitare drift           |
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
        PrintFormat("[ANTI-DRIFT] Ricalcolo completo somme Hurst: Sum=%.6f SumSq=%.6f (size=%d)",
            g_hurstSum, g_hurstSumSq, g_hurstHistorySize);
    }
}

//+------------------------------------------------------------------+
//| FILTRO HURST: Check finale prima di aprire trade                 |
//| Ritorna true se il trade  permesso, false se bloccato           |
//| NOTA: Il ricalcolo avviene ora in RecalculateOrganicSystem()     |
//|  FIX: Con fallback, non bloccare mai permanentemente           |
//+------------------------------------------------------------------+
bool IsTradeAllowedByHurst()
{
    if (!EnableHurstFilter) return true;  // Filtro disabilitato

    // OPTION 1 (SOFT): non bloccare le entry, ma applicare una penalita' di soglia in ExecuteVotingLogic().
    // Questo evita di “tagliare” tutto in regime random e lascia spazio a segnali molto forti.
    if (EnableHurstSoftMode) {
        if (!g_hurstReady) {
            // Manteniamo comunque il log di warmup per trasparenza.
            int logInterval = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
            static int hurstNotReadyCountSoft = 0;
            hurstNotReadyCountSoft++;
            if (hurstNotReadyCountSoft == 1 || hurstNotReadyCountSoft % logInterval == 0) {
                PrintFormat("[HURST] Hurst NON pronto (%d barre) - soft mode: trading NON bloccato (penalita' soglia disattiva)", hurstNotReadyCountSoft);
            }
        }
        return true;
    }
    
    // Il ricalcolo avviene ad ogni nuova barra in RecalculateOrganicSystem()
    // Qui verifichiamo solo il flag
    if (!g_hurstReady) {
        // Log ogni periodo naturale barre per evitare spam
        int logInterval = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
        static int hurstNotReadyCount = 0;
        hurstNotReadyCount++;
        if (hurstNotReadyCount == 1 || hurstNotReadyCount % logInterval == 0) {
            PrintFormat("[HURST] Hurst NON pronto (%d barre) - servono piu' dati per zona/stdev", hurstNotReadyCount);
        }
        //  FIX DATA-DRIVEN: Timeout = periodo minimo  scale(H) - adattivo al mercato
        int warmupTimeout = (int)MathRound(logInterval * GetOrganicScale(GetDefaultHurst()));
        if (hurstNotReadyCount > warmupTimeout) {
            if (hurstNotReadyCount == warmupTimeout + 1) {
                PrintFormat("[HURST] Fallback attivato: trading permesso dopo %d barre senza dati Hurst", warmupTimeout);
            }
            return true;  // Fallback: permetti trade
        }
        return false;
    }
    //  FIX: Log "TRADE BLOCCATO" rimosso - stampato in ExecuteTrades solo se c'era segnale
    
    return g_hurstAllowTrade;
}

//+------------------------------------------------------------------+
//| OPTION 1 (SOFT): moltiplicatore soglia entry basato su Hurst      |
//| - Se HurstTradeScore < TradeScoreThreshold: aumenta la soglia     |
//| - Se HurstTradeScore >= TradeScoreThreshold: nessuna penalita'    |
//| Nota: non fa blocco hard, solo modulazione aggressivita'          |
//+------------------------------------------------------------------+
double GetHurstSoftThresholdMultiplier()
{
    if (!EnableHurstFilter) return 1.0;
    if (!EnableHurstSoftMode) return 1.0;
    if (!g_hurstReady) return 1.0;

    // Se il filtro "hard" permetterebbe comunque, niente penalita'.
    if (g_hurstAllowTrade) return 1.0;

    double baseThr = g_tradeScoreThreshold;
    if (baseThr <= 0.0) return 1.0;

    double maxPenaltyPct = MathMax(0.0, HurstSoftMaxPenaltyPct);
    if (maxPenaltyPct <= 0.0) return 1.0;
    if (maxPenaltyPct > 300.0) maxPenaltyPct = 300.0; // safety: max x4

    // deficit in [0..1]
    double deficit = (baseThr - g_hurstTradeScore) / baseThr;
    if (deficit < 0.0) deficit = 0.0;
    if (deficit > 1.0) deficit = 1.0;

    double maxMult = 1.0 + (maxPenaltyPct / 100.0);
    double mult = 1.0 + deficit * (maxMult - 1.0);
    if (mult < 1.0) mult = 1.0;
    return mult;
}

// Tag compatto per i log [DECISION]
string GetHurstSoftDecisionTag(bool includeScore)
{
    if (!g_lastHurstSoftActive) return "";
    if (includeScore) {
        return StringFormat(" | HurstSoft x%.2f effThr=%.1f%% baseThr=%.1f%% score=%.1f%%",
            g_lastHurstSoftMult, g_lastThresholdEffPct, g_lastThresholdBasePct, g_lastScorePct);
    }
    return StringFormat(" | HurstSoft x%.2f effThr=%.1f%%",
        g_lastHurstSoftMult, g_lastThresholdEffPct);
}

//+------------------------------------------------------------------+
//| SOGLIA DINAMICA: Inizializza buffer score storici                |
//+------------------------------------------------------------------+
void InitScoreHistoryBuffer()
{
    ArrayResize(g_scoreHistory, SCORE_HISTORY_MAX);
    ArrayInitialize(g_scoreHistory, 0);
    g_scoreHistorySize = 0;
    g_scoreHistoryIndex = 0;
    g_dynamicThreshold = ScoreThreshold;  // Inizia con valore manuale
    g_scoreThresholdReady = false;
    
    // CRITICO: Inizializza somme incrementali Score
    g_scoreSum = 0.0;
    g_scoreSumSq = 0.0;
    
    if (g_enableLogsEffective) {
        PrintFormat("[INIT-BUFFER] g_scoreHistory: ArraySize=%d (max=%d) %s",
            ArraySize(g_scoreHistory), SCORE_HISTORY_MAX,
            ArraySize(g_scoreHistory) == SCORE_HISTORY_MAX ? "OK" : "WARN");
        if (AutoScoreThreshold) {
            Print("[INIT-BUFFER] Soglia score dinamica attiva: mean + stdev * decay(H)");
        } else {
            PrintFormat("[INIT-BUFFER] Soglia score manuale: %.1f%%", ScoreThreshold);
        }
    }
}

//+------------------------------------------------------------------+
//| SOGLIA DINAMICA: Aggiungi score al buffer circolare              |
//| OTTIMIZZATO: Usa somme incrementali O(1)                         |
//| FIX: Ricalcolo periodico completo per evitare drift numerico     |
//| INPUT: scorePct puo' essere qualsiasi valore (0-100%)            |
//+------------------------------------------------------------------+
void AddScoreToHistory(double scorePct)
{
    if (!AutoScoreThreshold) return;  // Non serve se soglia manuale
    
    //  SAFETY: Usa ArraySize() per dimensione reale
    int scoreMax = ArraySize(g_scoreHistory);
    if (scoreMax <= 0) return;  // Safety check
    
    //  FIX: Ricalcolo completo periodico per evitare drift floating point
    g_scoreOperationCount++;
    if (g_scoreOperationCount >= scoreMax) {
        RecalculateScoreSumsFromScratch();
        g_scoreOperationCount = 0;
    }
    
    //  VALIDATO: Sottrai valore vecchio se buffer pieno
    if (g_scoreHistorySize == scoreMax) {
        double oldValue = g_scoreHistory[g_scoreHistoryIndex];
        g_scoreSum -= oldValue;
        g_scoreSumSq -= oldValue * oldValue;
        
        //  SANITY CHECK: protezione da errori floating point accumulati
        if (g_scoreSum < 0) g_scoreSum = 0;
        if (g_scoreSumSq < 0) g_scoreSumSq = 0;
    }
    
    //  VALIDATO: Aggiungi nuovo valore
    g_scoreHistory[g_scoreHistoryIndex] = scorePct;
    g_scoreSum += scorePct;
    g_scoreSumSq += scorePct * scorePct;
    
    //  VALIDATO: Indice sempre nel range [0, arraySize-1]
    g_scoreHistoryIndex = (g_scoreHistoryIndex + 1) % scoreMax;
    
    //  VALIDATO: Size mai > arraySize
    if (g_scoreHistorySize < scoreMax) {
        g_scoreHistorySize++;
    }
}

//+------------------------------------------------------------------+
//|  FIX: Ricalcolo completo somme Score per evitare drift         |
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
        PrintFormat("[ANTI-DRIFT] Ricalcolo completo somme Score: Sum=%.2f SumSq=%.2f (size=%d)",
            g_scoreSum, g_scoreSumSq, g_scoreHistorySize);
    }
}

//+------------------------------------------------------------------+
//|  v1.1 FIX: Registra score per un nuovo trade aperto            |
//| Salva ticket  score mapping per collegamento a chiusura         |
//+------------------------------------------------------------------+
void RegisterOpenTradeScore(ulong ticket, double scorePct)
{
    int ticketsMax = ArraySize(g_openTickets);
    if (ticket == 0 || ticketsMax == 0) return;
    
    // Cerca slot libero (ticket == 0) o stesso ticket (update)
    int freeSlot = -1;
    for (int i = 0; i < ticketsMax; i++) {
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
            PrintFormat("[YOUDEN] Score %.1f%% registrato per ticket #%I64u", scorePct, ticket);
        }
    } else {
        // Buffer pieno - cerca la posizione pi vecchia che potrebbe essere chiusa
        // Strategia: sovrascriviamo la prima posizione (FIFO - First In First Out)
        // Questo  corretto perch le posizioni pi vecchie hanno maggiore probabilit di essere chiuse
        // Nota: slot 0 non  arbitrario ma  l'entry point FIFO naturale
        g_openTickets[0] = ticket;
        g_openScores[0] = scorePct;
        if (g_enableLogsEffective) {
            Print("[YOUDEN] WARN: buffer pieno - sovrascritto slot piu vecchio (FIFO)");
        }
    }
}

//+------------------------------------------------------------------+
//|  v1.1 FIX: Recupera score per un trade chiuso                  |
//| Cerca ticket nella mappa e rimuove dopo il recupero              |
//+------------------------------------------------------------------+
double GetAndRemoveTradeScore(ulong ticket)
{
    //  SAFETY: Usa ArraySize() per dimensione reale
    int ticketsMax = ArraySize(g_openTickets);
    if (ticket == 0 || ticketsMax == 0) return 0.0;
    
    for (int i = 0; i < ticketsMax; i++) {
        if (g_openTickets[i] == ticket) {
            double score = g_openScores[i];
            // Rimuovi dalla mappa
            g_openTickets[i] = 0;
            g_openScores[i] = 0.0;
            if (g_openTicketsCount > 0) g_openTicketsCount--;
            
            if (g_enableLogsEffective) {
                PrintFormat("[YOUDEN] Score %.1f%% recuperato per ticket #%I64u", score, ticket);
            }
            return score;
        }
    }
    
    // Ticket non trovato - potrebbe essere trade pre-v1.1 o errore
    return 0.0;
}

// Lettura NON distruttiva: utile per chiusure parziali (posizione ancora aperta)
bool GetTradeScore(ulong ticket, double &outScore)
{
    outScore = 0.0;
    int ticketsMax = ArraySize(g_openTickets);
    if (ticket == 0 || ticketsMax == 0) return false;
    for (int i = 0; i < ticketsMax; i++) {
        if (g_openTickets[i] == ticket) {
            outScore = g_openScores[i];
            return (outScore > 0.0);
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//|  FIX: Risolve positionId reale partendo dal deal ticket          |
//| In MT5: deal ticket e position id sono concetti diversi.        |
//| Usiamo DEAL_POSITION_ID per matching stabile in OnTradeTransaction|
//+------------------------------------------------------------------+
ulong ResolvePositionIdFromDealTicket(ulong dealTicket)
{
    if (dealTicket == 0) return 0;

    datetime toTime = TimeCurrent();
    datetime fromTime = toTime - 86400 * 3650;  // 10 anni (robusto in backtest)
    if (!HistorySelect(fromTime, toTime)) return 0;

    if (!HistoryDealSelect(dealTicket)) return 0;

    long posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
    if (posId <= 0) return 0;
    return (ulong)posId;
}

//+------------------------------------------------------------------+
//|  FIX: Enforce array ordering (non-series)                        |
//| Tutto il codice usa lastIdx = count-1 come barra piu recente.    |
//| Quindi vogliamo array in ordine "oldest -> newest" (series=false)|
//+------------------------------------------------------------------+
void SetTimeFrameArraysNonSeries(TimeFrameData &data)
{
    ArraySetAsSeries(data.rates, false);
    ArraySetAsSeries(data.ema, false);
    ArraySetAsSeries(data.macd, false);
    ArraySetAsSeries(data.macd_signal, false);
    ArraySetAsSeries(data.psar, false);
    ArraySetAsSeries(data.sma_fast, false);
    ArraySetAsSeries(data.sma_slow, false);
    ArraySetAsSeries(data.ichimoku_tenkan, false);
    ArraySetAsSeries(data.ichimoku_kijun, false);
    ArraySetAsSeries(data.ichimoku_senkou_a, false);
    ArraySetAsSeries(data.ichimoku_senkou_b, false);
    ArraySetAsSeries(data.adx, false);
    ArraySetAsSeries(data.di_plus, false);
    ArraySetAsSeries(data.di_minus, false);
    ArraySetAsSeries(data.bb_upper, false);
    ArraySetAsSeries(data.bb_middle, false);
    ArraySetAsSeries(data.bb_lower, false);
    ArraySetAsSeries(data.atr, false);
    ArraySetAsSeries(data.ha_open, false);
    ArraySetAsSeries(data.ha_close, false);
    ArraySetAsSeries(data.obv, false);
    ArraySetAsSeries(data.rsi, false);
    ArraySetAsSeries(data.stoch_main, false);
    ArraySetAsSeries(data.stoch_signal, false);
}

//+------------------------------------------------------------------+
//|  FIX: Ricalcolo completo somme TradeScore per evitare drift    |
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
        PrintFormat("[ANTI-DRIFT] Ricalcolo completo somme TradeScore: Sum=%.6f SumSq=%.6f (size=%d)",
            g_tradeScoreSum, g_tradeScoreSumSq, g_tradeScoreHistorySize);
    }
}

//+------------------------------------------------------------------+
//|  OTSU: Soglia che massimizza varianza inter-classe             |
//| Trova il punto di separazione naturale tra score "deboli" e      |
//| score "forti" nella distribuzione storica                        |
//| INPUT: array score storici                                       |
//| OUTPUT: soglia ottimale [0-100] che separa le due classi         |
//|  100% DATA-DRIVEN: nessun numero fisso arbitrario             |
//+------------------------------------------------------------------+
double CalcOtsuThreshold()
{
    // Minimo campioni = periodo  decay(H) (persistenza bassa = serve meno)
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    int minSamples = MathMax(4, (int)MathRound(basePeriod * GetOrganicDecayPow(GetDefaultHurst(), 2.0)));
    if (g_scoreHistorySize < minSamples) {
        // Fallback: percentile decay(H) dei dati esistenti (data-driven)
        if (g_scoreHistorySize > 0) {
            double decayFallback = GetOrganicDecay(g_hurstGlobal);  // ~0.62 per H=0.7
            return CalculatePercentile(g_scoreHistory, g_scoreHistorySize, decayFallback * 100.0);
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
        
        // Varianza inter-classe = wB * wF * (meanB - meanF)
        double variance = wB * wF * (meanB - meanF) * (meanB - meanF);
        
        if (variance > maxVariance) {
            maxVariance = variance;
            optimalThreshold = t;
        }
    }
    
    return optimalThreshold;
}

//+------------------------------------------------------------------+
//|  YOUDEN J: Soglia che massimizza (Sensitivity + Specificity -1)|
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
    int tradesMax = ArraySize(g_recentTrades);
    if (g_recentTradesCount < g_minTradesForYouden || tradesMax <= 0) return 0.0;  // Non pronto
    
    // Raccogli tutti i trade con score valido
    double scores[];
    double profits[];
    int validCount = 0;
    
    ArrayResize(scores, g_recentTradesCount);
    ArrayResize(profits, g_recentTradesCount);
    
    for (int i = 0; i < g_recentTradesCount; i++) {
        int idx = (g_recentTradesIndex - g_recentTradesCount + i + tradesMax) % tradesMax;
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
    
    // Range test DATA-DRIVEN: da decay(H) a (1-decay(H)) della distribuzione score
    double decayH2Youden = GetOrganicDecayPow(g_hurstGlobal, 2.0);  // ~0.25 per H=0.5
    double minScoreTest = CalculatePercentile(scores, validCount, decayH2Youden * 100.0);           // ~25%
    double maxScoreTest = CalculatePercentile(scores, validCount, (1.0 - decayH2Youden) * 100.0);  // ~75%
    
    // Fallback iniziale = percentile decay(H) degli score (data-driven)
    double decayYouden = GetOrganicDecay(g_hurstGlobal);  // ~0.62 per H=0.7
    double optimalThreshold = CalculatePercentile(scores, validCount, decayYouden * 100.0);
    
    // Step = range / scale(H) per avere ~8 test (H=0.5) o pi (H alto)
    // Minimo step = decay(H) empirico per granularit sufficiente
    double scale3 = GetOrganicScalePow(g_hurstGlobal, 3.0);  // scale(H)
    double minStep = GetOrganicDecayPow(g_hurstGlobal, 3.0);  // decay(H) empirico
    double stepSize = MathMax(minStep, (maxScoreTest - minScoreTest) / scale3);
    
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
    
    // Log se J  significativo (soglia da Hurst: decay  0.25 per H=0.5)
    double jLogThreshold = GetOrganicDecayPow(g_hurstGlobal, 2.0);  // decay(H) - J deve essere almeno questo per essere "significativo"
    if (g_enableLogsEffective && maxJ > jLogThreshold) {
        PrintFormat("[YOUDEN] J=%.3f | Soglia ottimale: %.1f%% | Trades analizzati: %d (W:%d L:%d)",
            maxJ, optimalThreshold, validCount, totalPositives, totalNegatives);
    }
    
    // Solo se J > 0 (meglio di random), altrimenti ritorna 0
    return (maxJ > 0) ? optimalThreshold : 0.0;
}

//+------------------------------------------------------------------+
//|  SOGLIA DINAMICA ADATTIVA: OTSU  YOUDEN                       |
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
    
    // 
    //  FASE 1: OTSU (warm-up - separazione statistica)
    // Trova la soglia che separa naturalmente gli score in due classi
    // 
    int minSamplesForOtsu = GetBufferSmall();  // 8 campioni
    
    if (g_scoreHistorySize < minSamplesForOtsu) {
        // Non abbastanza dati per Otsu: usa fallback manuale
        g_dynamicThreshold = ScoreThreshold;
        g_scoreThresholdReady = false;
        if (g_enableLogsEffective) {
            PrintFormat("[THRESHOLD]  Warm-up: %d/%d score | Fallback: %.1f%%",
                g_scoreHistorySize, minSamplesForOtsu, ScoreThreshold);
        }
        return;
    }
    
    // Calcola soglia Otsu
    g_otsuThreshold = CalcOtsuThreshold();
    
    // 
    //  FASE 2: YOUDEN (feedback - basato su profitti reali)
    // Quando abbiamo abbastanza trade con risultati, usiamo Youden
    // che massimizza (TPR + TNR - 1) basandosi sui profitti/perdite
    // 
    
    // Conta trade con score valido
    int tradesMax = ArraySize(g_recentTrades);
    if (tradesMax <= 0) return;  // Safety check
    
    int tradesWithScore = 0;
    for (int i = 0; i < g_recentTradesCount; i++) {
        int idx = (g_recentTradesIndex - g_recentTradesCount + i + tradesMax) % tradesMax;
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
    
    // 
    //  SAFETY BOUNDS (data-driven percentili)
    // Min: P25  25% (sotto questo, troppi segnali)
    // Max: P75  75% della distribuzione
    // 
    int minSamplesForBounds = GetBufferSmall();  // 8 campioni minimi
    if (g_scoreHistorySize >= minSamplesForBounds) {
        // Percentili da Hurst:
        // Floor: decay(H) ~ 25% della distribuzione per H=0.5
        // Ceiling: 1-decay(H) ~ 75% della distribuzione per H=0.5
        double decayH2 = GetOrganicDecayPow(g_hurstGlobal, 2.0);
        double floorPercentile = decayH2 * 100.0;           // ~25% per H=0.5
        double ceilingPercentile = (1.0 - decayH2) * 100.0; // ~75% per H=0.5
        
        double minBound = CalculatePercentile(g_scoreHistory, g_scoreHistorySize, floorPercentile);
        double maxBound = CalculatePercentile(g_scoreHistory, g_scoreHistorySize, ceilingPercentile);
        
        bool hitFloor = (g_dynamicThreshold < minBound);
        bool hitCeiling = (g_dynamicThreshold > maxBound);
        
        g_dynamicThreshold = MathMax(minBound, MathMin(maxBound, g_dynamicThreshold));
        
        if (hitFloor || hitCeiling) {
            thresholdMethod += (hitFloor ? " | FLOOR->P25" : " | CEILING->P75");
        }
    }
    
    // Log se cambio significativo (soglia cambio = decay^2 ~ 0.25)
    double logChangeThreshold = GetOrganicDecayPow(g_hurstGlobal > 0 ? g_hurstGlobal : GetDefaultHurst(), 2.0);
    if (g_enableLogsEffective && MathAbs(g_dynamicThreshold - oldThreshold) > logChangeThreshold) {
        PrintFormat("[THRESHOLD %s] Soglia: %.1f%% -> %.1f%% [%s] | H=%.3f",
            TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
            oldThreshold, g_dynamicThreshold, thresholdMethod, g_hurstGlobal);
        PrintFormat("   Otsu: %.1f%% | Youden: %.1f%% (%s) | Score buffer: %d | Trades: %d",
            g_otsuThreshold, g_youdenThreshold, g_youdenReady ? "ATTIVO" : "warm-up", 
            g_scoreHistorySize, g_recentTradesCount);
        
        // Statistiche distribuzione score per debug
        if (g_scoreHistorySize > 0) {
            double scoreMean = g_scoreSum / g_scoreHistorySize;
            double scoreStdev = MathSqrt(MathMax(0, (g_scoreSumSq / g_scoreHistorySize) - (scoreMean * scoreMean)));
            PrintFormat("   Score distribution: Mean=%.1f%% StDev=%.1f%% Range=[%.1f%%, %.1f%%]",
                scoreMean, scoreStdev, 
                CalculatePercentile(g_scoreHistory, g_scoreHistorySize, 0),
                CalculatePercentile(g_scoreHistory, g_scoreHistorySize, 100));
        }
    }
}

//+------------------------------------------------------------------+
//|  SOGLIA DINAMICA: Ottieni soglia corrente (auto o manuale)     |
//| Sistema OTSU  YOUDEN: impara dai dati E dai risultati           |
//| OUTPUT: Valore sempre >= 0 (soglia valida)                       |
//+------------------------------------------------------------------+
double GetCurrentThreshold()
{
    if (AutoScoreThreshold) {
        // Se la soglia automatica non  ancora pronta, usa fallback manuale
        if (!g_scoreThresholdReady) return ScoreThreshold;
        return g_dynamicThreshold;  // Otsu o Youden
    }
    return ScoreThreshold;  // Manuale
}

//+------------------------------------------------------------------+
//| DETECTOR INVERSIONE: Inizializzazione buffer                  |
//+------------------------------------------------------------------+
void InitReversalDetectors()
{
    // Score Momentum buffer = 64 (BUFFER_SIZE_XLARGE)
    int momentumBufferSize = GetBufferXLarge();  // 64
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
    
    // RSI Divergence: buffer swing = 16 (BUFFER_SIZE_MEDIUM)
    g_swingsMax = GetBufferMedium();  // 16
    ArrayResize(g_swings_H1, g_swingsMax);
    g_swingsSize_H1 = 0;
    g_divergenceSignal = 0;
    g_divergenceStrength = 0.0;
    
    // SOGLIA DIVERGENZA DATA-DRIVEN: buffer = 16 (BUFFER_SIZE_MEDIUM)
    int divergenceBufferSize = GetBufferMedium();  // 16
    ArrayResize(g_divergenceHistory, divergenceBufferSize);
    ArrayInitialize(g_divergenceHistory, 0);
    g_divergenceHistorySize = 0;
    g_divergenceHistoryIndex = 0;
    g_divergenceSum = 0.0;
    g_divergenceSumSq = 0.0;
    // Start con decay^2 (~0.25 per H=0.5) - verr aggiornato dai dati
    g_divergenceMinThreshold = GetOrganicDecayPow(GetDefaultHurst(), 2.0);
    g_divergenceThresholdReady = false;
    
    // SOGLIA REVERSAL DATA-DRIVEN: buffer = 64 (BUFFER_SIZE_XLARGE)
    int reversalBufferSize = GetBufferXLarge();  // 64
    ArrayResize(g_reversalStrengthHistory, reversalBufferSize);
    ArrayInitialize(g_reversalStrengthHistory, 0);
    g_reversalHistorySize = 0;
    g_reversalHistoryIndex = 0;
    g_reversalSum = 0.0;
    g_reversalSumSq = 0.0;
    // Start con decay (~0.62 per H=0.5) - verr aggiornato dai dati
    g_reversalThreshold = GetOrganicDecay(GetDefaultHurst());
    g_reversalThresholdReady = false;
    
    // STOCHASTIC EXTREME E OBV DIVERGENCE (v1.1)
    g_stochExtremeSignal = 0;
    g_stochExtremeStrength = 0.0;
    g_obvDivergenceSignal = 0;
    g_obvDivergenceStrength = 0.0;
    
    //  INIZIALIZZA TRACCIAMENTO RESIZE DINAMICO
    g_lastHurstForResize = g_hurstGlobal;
    g_lastMomentumBufferSize = momentumBufferSize;
    g_lastDivergenceBufferSize = divergenceBufferSize;
    g_lastReversalBufferSize = reversalBufferSize;
    
    if (g_enableLogsEffective) {
        Print("");
        Print("---------------------------------------------------------------");
        Print("DETECTOR INVERSIONE ORGANICO INIZIALIZZATO (v1.1)");
        PrintFormat("   Score Momentum buffer: %d | Soglia: mean + stdev * decay(H)", momentumBufferSize);
        Print("   Regime Change: traccia transizioni Hurst");
        PrintFormat("   RSI Divergence: %d swing points | Soglia: mean + stdev * decay(H) (%s)", 
            g_swingsMax, enableRSI ? "ATTIVO" : "disattivo");
        PrintFormat("   Stochastic Extreme: soglie percentili (P25/P75) (%s)", 
            enableStoch ? "ATTIVO" : "disattivo");
        PrintFormat("   OBV Divergence: lookback ~4 barre (%s)", 
            enableOBV ? "ATTIVO" : "disattivo");
        PrintFormat("   Divergence buffer: %d | Reversal buffer: %d", divergenceBufferSize, reversalBufferSize);
        Print("---------------------------------------------------------------");
        Print("");
    }
}

//+------------------------------------------------------------------+
//|  RESIZE DINAMICO BUFFER: Adatta dimensioni al regime Hurst     |
//| Chiamata quando Hurst cambia significativamente (H > threshold) |
//| Preserva i dati esistenti quanto possibile                       |
//+------------------------------------------------------------------+
void ResizeDynamicBuffers()
{
    // Calcola nuove dimensioni buffer basate su Hurst corrente
    int newMomentumSize = GetBufferXLarge();
    int newDivergenceSize = GetBufferMedium();
    int newReversalSize = GetBufferXLarge();
    
    bool needResize = false;
    
    // 
    // 1. MOMENTUM BUFFER RESIZE
    // 
    if (newMomentumSize != g_lastMomentumBufferSize) {
        int oldSize = ArraySize(g_momentumHistory);
        double tempArray[];
        
        // Salva dati esistenti
        ArrayResize(tempArray, g_momentumHistorySize);
        for (int i = 0; i < g_momentumHistorySize; i++) {
            int idx = (g_momentumHistoryIndex - g_momentumHistorySize + i + oldSize) % oldSize;
            tempArray[i] = g_momentumHistory[idx];
        }
        
        // Ridimensiona array
        ArrayResize(g_momentumHistory, newMomentumSize);
        ArrayInitialize(g_momentumHistory, 0);
        
        // Ripristina dati (prendi gli ultimi N se nuovo buffer pi piccolo)
        int dataToRestore = MathMin(g_momentumHistorySize, newMomentumSize);
        int startIdx = g_momentumHistorySize - dataToRestore;
        
        g_momentumHistoryIndex = 0;
        g_momentumHistorySize = 0;
        g_momentumSum = 0;
        g_momentumSumSq = 0;
        
        for (int i = 0; i < dataToRestore; i++) {
            double val = tempArray[startIdx + i];
            g_momentumHistory[g_momentumHistoryIndex] = val;
            g_momentumSum += val;
            g_momentumSumSq += val * val;
            g_momentumHistoryIndex = (g_momentumHistoryIndex + 1) % newMomentumSize;
            g_momentumHistorySize++;
        }
        
        g_lastMomentumBufferSize = newMomentumSize;
        needResize = true;
    }
    
    // 
    // 2. DIVERGENCE BUFFER RESIZE
    // 
    if (newDivergenceSize != g_lastDivergenceBufferSize) {
        int oldSize = ArraySize(g_divergenceHistory);
        double tempArray[];
        
        ArrayResize(tempArray, g_divergenceHistorySize);
        for (int i = 0; i < g_divergenceHistorySize; i++) {
            int idx = (g_divergenceHistoryIndex - g_divergenceHistorySize + i + oldSize) % oldSize;
            tempArray[i] = g_divergenceHistory[idx];
        }
        
        ArrayResize(g_divergenceHistory, newDivergenceSize);
        ArrayInitialize(g_divergenceHistory, 0);
        
        int dataToRestore = MathMin(g_divergenceHistorySize, newDivergenceSize);
        int startIdx = g_divergenceHistorySize - dataToRestore;
        
        g_divergenceHistoryIndex = 0;
        g_divergenceHistorySize = 0;
        g_divergenceSum = 0;
        g_divergenceSumSq = 0;
        
        for (int i = 0; i < dataToRestore; i++) {
            double val = tempArray[startIdx + i];
            g_divergenceHistory[g_divergenceHistoryIndex] = val;
            g_divergenceSum += val;
            g_divergenceSumSq += val * val;
            g_divergenceHistoryIndex = (g_divergenceHistoryIndex + 1) % newDivergenceSize;
            g_divergenceHistorySize++;
        }
        
        g_lastDivergenceBufferSize = newDivergenceSize;
        needResize = true;
    }
    
    // 
    // 3. REVERSAL BUFFER RESIZE
    // 
    if (newReversalSize != g_lastReversalBufferSize) {
        int oldSize = ArraySize(g_reversalStrengthHistory);
        double tempArray[];
        
        ArrayResize(tempArray, g_reversalHistorySize);
        for (int i = 0; i < g_reversalHistorySize; i++) {
            int idx = (g_reversalHistoryIndex - g_reversalHistorySize + i + oldSize) % oldSize;
            tempArray[i] = g_reversalStrengthHistory[idx];
        }
        
        ArrayResize(g_reversalStrengthHistory, newReversalSize);
        ArrayInitialize(g_reversalStrengthHistory, 0);
        
        int dataToRestore = MathMin(g_reversalHistorySize, newReversalSize);
        int startIdx = g_reversalHistorySize - dataToRestore;
        
        g_reversalHistoryIndex = 0;
        g_reversalHistorySize = 0;
        g_reversalSum = 0;
        g_reversalSumSq = 0;
        
        for (int i = 0; i < dataToRestore; i++) {
            double val = tempArray[startIdx + i];
            g_reversalStrengthHistory[g_reversalHistoryIndex] = val;
            g_reversalSum += val;
            g_reversalSumSq += val * val;
            g_reversalHistoryIndex = (g_reversalHistoryIndex + 1) % newReversalSize;
            g_reversalHistorySize++;
        }
        
        g_lastReversalBufferSize = newReversalSize;
        needResize = true;
    }
    
    // Log del resize
    if (needResize && g_enableLogsEffective) {
        Print("----------------------------------------------------------");
        Print("BUFFER DINAMICI RIDIMENSIONATI (adattamento Hurst)");
        PrintFormat("   H: %.3f -> %.3f (dH=%.3f)", g_lastHurstForResize, g_hurstGlobal,
                    g_hurstGlobal - g_lastHurstForResize);
        PrintFormat("   Momentum: %d -> %d | Divergence: %d -> %d | Reversal: %d -> %d",
                    g_lastMomentumBufferSize, newMomentumSize,
                    g_lastDivergenceBufferSize, newDivergenceSize,
                    g_lastReversalBufferSize, newReversalSize);
        Print("   Dati storici preservati e statistiche ricalcolate");
        Print("----------------------------------------------------------");
    }
    
    g_lastHurstForResize = g_hurstGlobal;
}

//+------------------------------------------------------------------+
//|  CHECK RESIZE: Verifica se serve ridimensionare i buffer       |
//| Chiamata ad ogni aggiornamento significativo di Hurst            |
//+------------------------------------------------------------------+
void CheckAndResizeBuffers()
{
    // Verifica se Hurst  cambiato significativamente
    double deltaH = MathAbs(g_hurstGlobal - g_lastHurstForResize);
    
    //  DATA-DRIVEN: Soglia = 2(H) storico (95% confidenza = cambio regime)
    double minThreshold = GetOrganicDecayPow(GetDefaultHurst(), 2.0);  // decay(H) empirico
    double resizeThreshold = MathMax(minThreshold, g_hurstStdev * 2.0);  // Fallback empirico se stdev non pronta
    if (deltaH > resizeThreshold) {
        ResizeDynamicBuffers();
    }
}

//+------------------------------------------------------------------+
//|  SCORE MOMENTUM: Aggiorna e calcola cambio score               |
//| Ritorna: +1 se momentum bullish forte, -1 se bearish, 0 neutro   |
//+------------------------------------------------------------------+
int UpdateScoreMomentum(double currentScore)
{
    // Calcola momentum (derivata dello score)
    g_scoreMomentum = currentScore - g_prevScore;
    g_prevScore = currentScore;
    
    // Aggiungi al buffer storico per calcolo soglia
    // IMPORTANTE: Usa ArraySize() per dimensione reale, non GetBufferXLarge() che pu cambiare!
    int momentumBufferMax = ArraySize(g_momentumHistory);
    if (momentumBufferMax <= 0) return 0;  // Safety check

    // Safety extra: se l'indice fosse corrotto, riallinea al buffer reale
    if (g_momentumHistoryIndex < 0 || g_momentumHistoryIndex >= momentumBufferMax) {
        g_momentumHistoryIndex = 0;
    }
    
    // Sottrai valore vecchio se buffer pieno (O(1))
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
    
    // Calcola soglia momentum = mean + stdev * decay(H)
    int minSamples = GetBufferSmall();  // 8
    if (g_momentumHistorySize >= minSamples) {
        double mean = g_momentumSum / g_momentumHistorySize;
        double meanSq = g_momentumSumSq / g_momentumHistorySize;
        double variance = meanSq - (mean * mean);
        double stdev = (variance > 0) ? MathSqrt(variance) : 0.0;
        g_scoreMomentumThreshold = mean + stdev * GetOrganicDecay(g_hurstGlobal);
        g_momentumThresholdReady = true;
    }
    
    // Determina segnale
    if (!g_momentumThresholdReady) return 0;
    
    if (MathAbs(g_scoreMomentum) >= g_scoreMomentumThreshold) {
        if (g_scoreMomentum > 0) {
            if (g_enableLogsEffective) {
                PrintFormat("[REVERSAL] MOMENTUM BULLISH: %.2f > %.2f soglia", 
                    g_scoreMomentum, g_scoreMomentumThreshold);
            }
            return 1;  // Momentum bullish significativo
        } else {
            if (g_enableLogsEffective) {
                PrintFormat("[REVERSAL] MOMENTUM BEARISH: %.2f < -%.2f soglia", 
                    g_scoreMomentum, g_scoreMomentumThreshold);
            }
            return -1;  // Momentum bearish significativo
        }
    }
    
    return 0;  // Momentum non significativo
}

//+------------------------------------------------------------------+
//| Helper: Converti enum regime in label stringa                    |
//+------------------------------------------------------------------+
string GetRegimeLabel(ENUM_HURST_REGIME regime)
{
    if (regime == HURST_TRENDING) return "TREND";
    if (regime == HURST_MEANREV) return "M-REV";
    return "RAND";
}

//+------------------------------------------------------------------+
//|  REGIME CHANGE: Traccia transizioni regime Hurst               |
//| Ritorna: +1 se verso trending, -1 se verso meanrev, 0 nessuna    |
//+------------------------------------------------------------------+
int UpdateRegimeChange()
{
    g_regimeChanged = false;
    g_regimeChangeDirection = 0;
    
    if (!EnableHurstFilter) return 0;
    
    // Check cambio per ogni TF attivo
    double changeScore = 0.0;  //  double per pesi data-driven
    
    //  PESI DATA-DRIVEN: derivati da 2^H
    // M5 = decay^2, H1 = decay, H4 = 1.0, D1 = scale
    double decay = GetOrganicDecay(g_hurstGlobal);
    double scale = GetOrganicScale(g_hurstGlobal);
    double weightM5 = decay * decay;   // ~0.36
    double weightH1 = decay;           // ~0.60
    double weightH4 = 1.0;             // 1.0
    double weightD1 = scale;           // ~1.66
    
    // M5 (peso decay^2 ~ 0.36)
    if (g_vote_M5_active && g_hurstRegime_M5 != g_prevRegime_M5) {
        if (g_hurstRegime_M5 == HURST_TRENDING && g_prevRegime_M5 != HURST_TRENDING) 
            changeScore += weightM5;
        else if (g_hurstRegime_M5 == HURST_MEANREV && g_prevRegime_M5 != HURST_MEANREV) 
            changeScore -= weightM5;
        g_prevRegime_M5 = g_hurstRegime_M5;
    }
    
    // H1 (peso decay ~ 0.62)
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
    
    // D1 (peso f ~= 1.62)
    if (g_vote_D1_active && g_hurstRegime_D1 != g_prevRegime_D1) {
        if (g_hurstRegime_D1 == HURST_TRENDING && g_prevRegime_D1 != HURST_TRENDING) 
            changeScore += weightD1;
        else if (g_hurstRegime_D1 == HURST_MEANREV && g_prevRegime_D1 != HURST_MEANREV) 
            changeScore -= weightD1;
        g_prevRegime_D1 = g_hurstRegime_D1;
    }
    
    //  FIX: Soglia rumore = decay(H) (~0.25 per H=0.5)
    double noiseThreshold = GetOrganicDecayPow(g_hurstGlobal, 2.0);
    if (MathAbs(changeScore) > noiseThreshold) {
        g_regimeChanged = true;
        g_regimeChangeDirection = (changeScore > 0) ? 1 : -1;
        
        if (g_enableLogsEffective) {
            string direction = changeScore > 0 ? " TRENDING" : " MEAN-REVERTING";
            PrintFormat("[REGIME %s] %s | Score: %.2f > %.2f soglia | H=%.3f",
                TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES), direction, 
                changeScore, noiseThreshold, g_hurstGlobal);
            PrintFormat("   Breakdown: M5=%s(%.2f) H1=%s(%.2f) H4=%s(%.2f) D1=%s(%.2f)",
                GetRegimeLabel(g_hurstRegime_M5), weightM5,
                GetRegimeLabel(g_hurstRegime_H1), weightH1,
                GetRegimeLabel(g_hurstRegime_H4), weightH4,
                GetRegimeLabel(g_hurstRegime_D1), weightD1);
        }
    }
    
    return g_regimeChangeDirection;
}

//+------------------------------------------------------------------+
//| AGGIORNA SOGLIA DIVERGENZA DATA-DRIVEN                           |
//| Traccia storia forze divergenza e calcola: mean + stdev * decay  |
//| Clamp: [P25 ~ 25%, P62 ~ 62%]                                    |
//+------------------------------------------------------------------+
void UpdateDivergenceThreshold(double strength)
{
    // IMPORTANTE: Usa ArraySize() per dimensione reale, non GetBufferMedium() che pu cambiare!
    int divergenceBufferMax = ArraySize(g_divergenceHistory);
    if (divergenceBufferMax <= 0) return;  // Safety check

    // Safety extra: se l'indice fosse corrotto, riallinea al buffer reale
    if (g_divergenceHistoryIndex < 0 || g_divergenceHistoryIndex >= divergenceBufferMax) {
        g_divergenceHistoryIndex = 0;
    }
    
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
    
    // Calcola soglia: minimo = periodo  decay(H) (data-driven)
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    int minSamples = MathMax(4, (int)MathRound(basePeriod * GetOrganicDecayPow(GetDefaultHurst(), 2.0)));
    
    if (g_divergenceHistorySize >= minSamples) {
        double mean = g_divergenceSum / g_divergenceHistorySize;
        double variance = (g_divergenceSumSq / g_divergenceHistorySize) - (mean * mean);
        double stdev = variance > 0 ? MathSqrt(variance) : 0;
        
        // Soglia = mean + stdev * decay(H) (divergenze significativamente sopra media)
        g_divergenceMinThreshold = mean + stdev * GetOrganicDecay(g_hurstGlobal);
        
        // Clamp data-driven: [decay^2 ~ 0.25, decay ~ 0.62]
        double minClamp = GetOrganicDecayPow(g_hurstGlobal, 2.0);
        double maxClamp = GetOrganicDecay(g_hurstGlobal);
        g_divergenceMinThreshold = MathMax(minClamp, MathMin(maxClamp, g_divergenceMinThreshold));
        
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
//| RSI DIVERGENCE: Rileva swing e divergenze prezzo/RSI          |
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
    
    // Servono almeno 16 barre per rilevare swing
    int minBars = GetBufferMedium();  // ~17
    if (ratesSize < minBars || rsiSize < minBars) return 0;
    
    // Lookback per swing detection = periodo  decay(H) (data-driven)
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    int swingLookback = MathMax(3, (int)MathRound(basePeriod * GetOrganicDecayPow(GetDefaultHurst(), 2.0)));
    
    // Cerca swing high/low recenti
    bool foundSwingHigh = false;
    bool foundSwingLow = false;
    double swingHighPrice = 0, swingHighRSI = 0;
    double swingLowPrice = 0, swingLowRSI = 0;
    int swingHighBar = 0, swingLowBar = 0;
    
    // Cerca swing negli ultimi 16 barre
    for (int i = swingLookback; i < minBars - swingLookback; i++) {
        int idx = ratesSize - 1 - i;  // Indice dalla fine (0 = pi recente)
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
    //  USA TUTTE LE BARRE DISPONIBILI per ricerca swing
    int searchEnd = ratesSize - swingLookback - 1;
    
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
            // Calcola forza divergenza (normalizzata con decay(H) come scala)
            double priceDiff = (swingHighPrice - prevSwingHighPrice) / prevSwingHighPrice;
            double rsiDiff = (prevSwingHighRSI - swingHighRSI) / prevSwingHighRSI;
            calcStrength = MathMin(1.0, (priceDiff + rsiDiff) / GetOrganicDecay(g_hurstGlobal));
            
            // AGGIORNA BUFFER E SOGLIA DATA-DRIVEN
            UpdateDivergenceThreshold(calcStrength);
            
            if (calcStrength >= g_divergenceMinThreshold) {
                g_divergenceStrength = calcStrength;
                g_divergenceSignal = -1;  // Bearish
                if (g_enableLogsEffective) {
                    PrintFormat("[REVERSAL] BEARISH DIV: HH (%.5f->%.5f) + LH RSI (%.1f->%.1f) | Forza: %.0f%% > Soglia: %.0f%%",
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
            // Calcola forza divergenza (normalizzata con decay(H) come scala)
            double priceDiff = (prevSwingLowPrice - swingLowPrice) / prevSwingLowPrice;
            double rsiDiff = (swingLowRSI - prevSwingLowRSI) / prevSwingLowRSI;
            calcStrength = MathMin(1.0, (priceDiff + rsiDiff) / GetOrganicDecay(g_hurstGlobal));
            
            // AGGIORNA BUFFER E SOGLIA DATA-DRIVEN
            UpdateDivergenceThreshold(calcStrength);
            
            if (calcStrength >= g_divergenceMinThreshold) {
                g_divergenceStrength = calcStrength;
                g_divergenceSignal = 1;  // Bullish
                if (g_enableLogsEffective) {
                    PrintFormat("[REVERSAL] BULLISH DIV: LL (%.5f->%.5f) + HL RSI (%.1f->%.1f) | Forza: %.0f%% > Soglia: %.0f%%",
                        prevSwingLowPrice, swingLowPrice, prevSwingLowRSI, swingLowRSI, 
                        g_divergenceStrength * 100, g_divergenceMinThreshold * 100);
                }
            }
        }
    }
    
    return g_divergenceSignal;
}

//+------------------------------------------------------------------+
//| STOCHASTIC EXTREME DETECTION                                     |
//| Rileva zone ipercomprato/ipervenduto usando soglie percentili    |
//| Soglia ipervenduto: < P25 * 100 ~ 25%                            |
//| Soglia ipercomprato: > P75 * 100 ~ 75%                           |
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
    
    // SOGLIE DA HURST: decay per estremi
    double decayH2 = GetOrganicDecayPow(g_hurstGlobal, 2.0);  // ~0.25 per H=0.5
    double oversoldLevel = decayH2 * 100.0;              // ~25% per H=0.5
    double overboughtLevel = (1.0 - decayH2) * 100.0;    // ~75% per H=0.5
    
    // Forza = quanto e' "estremo" rispetto alla soglia
    // Per ipervenduto: quanto e' sotto 23.6%
    // Per ipercomprato: quanto e' sopra 76.4%
    
    if (stochK < oversoldLevel && stochD < oversoldLevel) {
        // IPERVENDUTO -> potenziale inversione bullish
        // Forza = distanza dalla soglia normalizzata (0-1)
        g_stochExtremeStrength = MathMin(1.0, (oversoldLevel - stochK) / oversoldLevel);
        g_stochExtremeSignal = 1;  // Bullish
        
        if (g_enableLogsEffective) {
            PrintFormat("[STOCH] IPERVENDUTO K=%.1f%% D=%.1f%% < %.1f%% | Forza: %.0f%%",
                stochK, stochD, oversoldLevel, g_stochExtremeStrength * 100);
        }
    }
    else if (stochK > overboughtLevel && stochD > overboughtLevel) {
        // IPERCOMPRATO ? potenziale inversione bearish
        g_stochExtremeStrength = MathMin(1.0, (stochK - overboughtLevel) / (100.0 - overboughtLevel));
        g_stochExtremeSignal = -1;  // Bearish
        
        if (g_enableLogsEffective) {
            PrintFormat("[STOCH] IPERCOMPRATO K=%.1f%% D=%.1f%% > %.1f%% | Forza: %.0f%%",
                stochK, stochD, overboughtLevel, g_stochExtremeStrength * 100);
        }
    }
    
    return g_stochExtremeSignal;
}

//+------------------------------------------------------------------+
//| OBV DIVERGENCE DETECTION                                      |
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
    
    // Servono almeno 16 barre
    int minBars = GetBufferMedium();  // ~17
    if (ratesSize < minBars || obvSize < minBars) return 0;
    
    // Lookback per trend detection = periodo  decay(H) (data-driven)
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    int lookback = MathMax(3, (int)MathRound(basePeriod * GetOrganicDecayPow(GetDefaultHurst(), 2.0)));
    
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
    
    //  SOGLIA MINIMA per considerare movimento significativo: decay(H) / 100
    // Per H=0.5: ~0.25/100 = 0.0025 (0.25%), per H=0.7: ~0.38/100 = 0.0038 (0.38%)
    double minChange = GetOrganicDecayPow(g_hurstGlobal, 2.0) / 100.0;
    
    if (MathAbs(priceChange) < minChange || MathAbs(obvChange) < minChange) return 0;
    
    // ---------------------------------------------------------------
    // BEARISH DIVERGENCE: Prezzo sale, OBV scende
    // ---------------------------------------------------------------
    if (priceChange > 0 && obvChange < 0) {
        // Forza = media normalizzata dei due cambiamenti
        g_obvDivergenceStrength = MathMin(1.0, (priceChange - obvChange) / GetOrganicDecay(g_hurstGlobal));
        g_obvDivergenceSignal = -1;  // Bearish
        
        if (g_enableLogsEffective) {
            PrintFormat("[OBV] BEARISH DIV: Prezzo +%.2f%% ma OBV %.2f%% | Forza: %.0f%%",
                priceChange * 100, obvChange * 100, g_obvDivergenceStrength * 100);
        }
    }
    // ---------------------------------------------------------------
    // BULLISH DIVERGENCE: Prezzo scende, OBV sale
    // ---------------------------------------------------------------
    else if (priceChange < 0 && obvChange > 0) {
        g_obvDivergenceStrength = MathMin(1.0, (obvChange - priceChange) / GetOrganicDecay(g_hurstGlobal));
        g_obvDivergenceSignal = 1;  // Bullish
        
        if (g_enableLogsEffective) {
            PrintFormat("[OBV] BULLISH DIV: Prezzo %.2f%% ma OBV +%.2f%% | Forza: %.0f%%",
                priceChange * 100, obvChange * 100, g_obvDivergenceStrength * 100);
        }
    }
    
    return g_obvDivergenceSignal;
}

//+------------------------------------------------------------------+
//| DETECTOR INVERSIONE MASTER: Combina tutti i segnali              |
//| Ritorna: +1 inversione bullish, -1 bearish, 0 nessuna            |
//| strength: 0-1 forza del segnale                                  |
//| SOGLIA 100% DATA-DRIVEN: mean + stdev * decay(H)                 |
//| v1.1: Include Stochastic Extreme e OBV Divergence                |
//+------------------------------------------------------------------+
int GetReversalSignal(double &strength, bool updateHistory = true)
{
    strength = 0.0;
    
    int momentumSignal = g_scoreMomentum > 0 ? 1 : (g_scoreMomentum < 0 ? -1 : 0);
    bool momentumStrong = MathAbs(g_scoreMomentum) >= g_scoreMomentumThreshold;
    
    int regimeSignal = g_regimeChangeDirection;
    int divergenceSignal = g_divergenceSignal;
    
    // NUOVI SEGNALI MEAN-REVERSION (v1.1)
    int stochExtremeSignal = g_stochExtremeSignal;
    int obvDivergenceSignal = g_obvDivergenceSignal;
    
    // ---------------------------------------------------------------
    // LOGICA COMBINATA (pesi organici Hurst-driven)
    // RSI Divergence = peso scale(H) (piu affidabile, classico)
    // OBV Divergence = peso 1 (volume conferma)
    // Stoch Extreme = peso decay(H) (zone estreme)
    // Momentum = peso decay^2 (rapido ma rumoroso)
    // Regime = peso decay^2 (confirmation)
    // ---------------------------------------------------------------
    double score = 0.0;
    double maxScore = 0.0;
    
    // Divergenza RSI (peso piu alto - classico e affidabile)
    if (divergenceSignal != 0) {
        double scale = GetOrganicScale(g_hurstGlobal);
        score += divergenceSignal * scale * g_divergenceStrength;
        maxScore += scale;
    }
    
    // Divergenza OBV (volume non mente - peso 1)
    if (obvDivergenceSignal != 0) {
        score += obvDivergenceSignal * 1.0 * g_obvDivergenceStrength;
        maxScore += 1.0;
    }
    
    // Stochastic Zone Estreme (peso decay(H))
    if (stochExtremeSignal != 0) {
        double decay = GetOrganicDecay(g_hurstGlobal);
        score += stochExtremeSignal * decay * g_stochExtremeStrength;
        maxScore += decay;
    }
    
    // Score Momentum (peso decay^2)
    if (momentumStrong) {
        double decaySq = GetOrganicDecayPow(g_hurstGlobal, 2);
        score += momentumSignal * decaySq;
        maxScore += decaySq;
    }
    
    // Regime Change (peso decay^2)
    if (regimeSignal != 0) {
        double decaySq = GetOrganicDecayPow(g_hurstGlobal, 2);
        score += regimeSignal * decaySq;
        maxScore += decaySq;
    }
    
    if (maxScore <= 0) return 0;
    
    // Calcola forza normalizzata
    strength = MathAbs(score) / maxScore;
    
    if (updateHistory) {
        // ---------------------------------------------------------------
        // AGGIORNA BUFFER STORICO FORZA REVERSAL (per soglia data-driven)
        // ---------------------------------------------------------------
        int reversalBufferMax = ArraySize(g_reversalStrengthHistory);
        if (reversalBufferMax <= 0) return 0;

        if (g_reversalHistoryIndex < 0 || g_reversalHistoryIndex >= reversalBufferMax) {
            g_reversalHistoryIndex = 0;
        }
        
        if (g_reversalHistorySize == reversalBufferMax) {
            double oldValue = g_reversalStrengthHistory[g_reversalHistoryIndex];
            g_reversalSum -= oldValue;
            g_reversalSumSq -= oldValue * oldValue;
            if (g_reversalSum < -1e10) g_reversalSum = 0;
            if (g_reversalSumSq < 0) g_reversalSumSq = 0;
        }
        
        g_reversalStrengthHistory[g_reversalHistoryIndex] = strength;
        g_reversalSum += strength;
        g_reversalSumSq += strength * strength;
        
        g_reversalHistoryIndex = (g_reversalHistoryIndex + 1) % reversalBufferMax;
        if (g_reversalHistorySize < reversalBufferMax) g_reversalHistorySize++;
        
        // ---------------------------------------------------------------
        //  CALCOLA SOGLIA DATA-DRIVEN: mean + stdev * decay(H)
        // ---------------------------------------------------------------
        int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
        int minSamples = MathMax(4, (int)MathRound(basePeriod * GetOrganicDecayPow(GetDefaultHurst(), 2.0)));
        
        if (g_reversalHistorySize >= minSamples) {
            double mean = g_reversalSum / g_reversalHistorySize;
            double variance = (g_reversalSumSq / g_reversalHistorySize) - (mean * mean);
            variance = MathMax(0.0, variance);
            double stdev = (variance > 0.0) ? MathSqrt(variance) : 0.0;
            
            g_reversalThreshold = mean + stdev * GetOrganicDecay(g_hurstGlobal);
            
            double decayClampMin = GetOrganicDecayPow(g_hurstGlobal, 2.0);
            double decayClampMax = GetOrganicDecay(g_hurstGlobal);
            g_reversalThreshold = MathMax(decayClampMin, MathMin(decayClampMax, g_reversalThreshold));
            
            if (!g_reversalThresholdReady) {
                g_reversalThresholdReady = true;
                if (g_enableLogsEffective) {
                    PrintFormat("[REVERSAL %s] Soglia data-driven pronta: %.1f%% (mean=%.1f%%, stdev=%.1f%%) | H=%.3f",
                        TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
                        g_reversalThreshold * 100, mean * 100, stdev * 100, g_hurstGlobal);
                    PrintFormat("   Buffer: %d/%d campioni | Range=[%.1f%%, %.1f%%] | Clamp=[%.1f%%, %.1f%%]",
                        g_reversalHistorySize, ArraySize(g_reversalStrengthHistory),
                        CalculatePercentile(g_reversalStrengthHistory, g_reversalHistorySize, 0) * 100,
                        CalculatePercentile(g_reversalStrengthHistory, g_reversalHistorySize, 100) * 100,
                        GetOrganicDecayPow(g_hurstGlobal, 2.0) * 100, GetOrganicDecay(g_hurstGlobal) * 100);
                }
            } else if (g_enableLogsEffective) {
                static int reversalLogCount = 0;
                reversalLogCount++;
                int logInterval = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
                if (reversalLogCount % logInterval == 0) {
                    PrintFormat("[REVERSAL] Update #%d: Soglia=%.1f%% (mean=%.1f%% stdev=%.1f%%) | %d campioni",
                        reversalLogCount, g_reversalThreshold * 100, mean * 100, stdev * 100, g_reversalHistorySize);
                }
            }
        }
    }
    
    // ---------------------------------------------------------------
    // DECISIONE: Forza > soglia data-driven
    // ---------------------------------------------------------------
    if (strength >= g_reversalThreshold) {
        int direction = (score > 0) ? 1 : -1;
        
        if (g_enableLogsEffective) {
            PrintFormat("[REVERSAL] INVERSIONE %s | Forza: %.0f%% > Soglia: %.0f%% | RSI=%s OBV=%s Stoch=%s M=%s R=%s",
                direction > 0 ? "BULLISH" : "BEARISH",
                strength * 100,
                g_reversalThreshold * 100,
                divergenceSignal > 0 ? "BUY" : (divergenceSignal < 0 ? "SELL" : "NEUTRO"),
                obvDivergenceSignal > 0 ? "BUY" : (obvDivergenceSignal < 0 ? "SELL" : "NEUTRO"),
                stochExtremeSignal > 0 ? "BUY" : (stochExtremeSignal < 0 ? "SELL" : "NEUTRO"),
                momentumStrong ? (momentumSignal > 0 ? "BUY" : "SELL") : "NEUTRO",
                regimeSignal > 0 ? "BUY" : (regimeSignal < 0 ? "SELL" : "NEUTRO"));
        }
        
        return direction;
    }
    
    return 0;
}

//+------------------------------------------------------------------+
//| Calcola il PERIODO NATURALE del mercato per un TF                |
//| Usa AUTOCORRELAZIONE per trovare il "memory decay" del prezzo    |
//| Il periodo naturale e dove l'autocorr scende sotto decay(H)      |
//| Ritorna anche l'ESPONENTE DI HURST per calcolo pesi              |
//| Questo e COMPLETAMENTE derivato dai dati, zero numeri arbitrari  |
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
    //  APPROCCIO 100% AUTO-ORGANIZZANTE (LOOKBACK ADATTIVO):
    // 1. Bootstrap: usa minimo statistico (BOOTSTRAP_MIN_BARS  fattore)
    // 2. Dopo primo calcolo: lookback = periodo_naturale  scale(H)  
    // 3. Il lookback emerge dal mercato e si adatta a cambi di regime
    // 4. maxLag = barre_disponibili  decay(H) (memoria adattiva)
    // 
    //  SISTEMA AUTO-ORGANIZZANTE:
    // - Trending (H>0.5): memoria lunga  lookback grande (scale>1)
    // - Ranging (H<0.5): memoria corta  lookback piccolo (scale<1)
    // - Periodo lungo: serve lookback proporzionale
    // - ZERO VALORI ARBITRARI: tutto derivato dal mercato
    // ---------------------------------------------------------------
    
    //  LOOKBACK ADATTIVO: dipende dal periodo naturale precedente o bootstrap
    int lookback = 0;
    if (tf == PERIOD_M5) lookback = g_lookback_M5;
    else if (tf == PERIOD_H1) lookback = g_lookback_H1;
    else if (tf == PERIOD_H4) lookback = g_lookback_H4;
    else if (tf == PERIOD_D1) lookback = g_lookback_D1;
    
    // Salva lookback iniziale per log
    int initialLookback = lookback;
    
    //  BOOTSTRAP INIZIALE: se lookback=0, usa minimo statistico  fattore empirico
    // Fattore dipende da Hurst: H>0.5  memoria lunga  fattore alto
    if (lookback == 0) {
        double memoryFactor = GetOrganicScalePow(GetDefaultHurst(), 2.0);  // scale(H) = base^(2*H)
        lookback = (int)MathRound(BOOTSTRAP_MIN_BARS * memoryFactor);
        lookback = MathMax(BOOTSTRAP_MIN_BARS * 2, lookback);  // Minimo 128 barre
    }
    
    int barsToRequest = lookback;
    
    //  Minimo PURO: 8 barre (sotto questo non ha senso statistico)
    int minBarsForAnalysis = GetBufferSmall();
    
    //  DIAGNOSTICA: Controlla quante barre sono disponibili PRIMA di copiare
    int barsAvailableTotal = Bars(_Symbol, tf);
    PrintFormat("[NATURAL] TF %s: Bars()=%d, richiesto=%d, minimo=%d", 
        EnumToString(tf), barsAvailableTotal, barsToRequest, minBarsForAnalysis);
    
    //  BOOTSTRAP ADATTIVO: Se ci sono meno barre del richiesto, usa quelle disponibili
    // purch siano almeno pari al minimo statistico
    if (barsAvailableTotal < barsToRequest && barsAvailableTotal >= minBarsForAnalysis) {
        PrintFormat("[NATURAL] TF %s: Adatto richiesta a %d barre disponibili (bootstrap)", 
            EnumToString(tf), barsAvailableTotal);
        barsToRequest = barsAvailableTotal - 1;  // -1 per escludere barra corrente
    }
    
    //  FIX: Usa CopyRates DIRETTAMENTE per caricare dati storici
    // In backtest, questo forza MT5 a caricare i dati dal passato!
    // Usiamo start=1 (barra precedente) per evitare la barra corrente incompleta
    int copied = CopyRates(_Symbol, tf, 1, barsToRequest, rates);
    
    if (copied < minBarsForAnalysis) {
        //  BOOTSTRAP DI EMERGENZA: se ci sono poche barre, usa il minimo statistico
        // ma NON spegnere il TF: assegna periodo=BOOTSTRAP_MIN_BARS e Hurst default
        PrintFormat("? [NATURAL] TF %s: copiate %d/%d barre (minimo %d) -> BOOTSTRAP MINIMO, TF ATTIVO", 
            EnumToString(tf), copied, barsToRequest, minBarsForAnalysis);
        result.period = BOOTSTRAP_MIN_BARS;
        result.hurstExponent = GetDefaultHurst();
        result.valid = true;
        return result;
    }
    
    // FIX: barsAvailable = numero EFFETTIVO di barre copiate (non Bars()!)
    int barsAvailable = copied;
    
    //  maxLag = barre  decay(H) (data-driven: pi memoria in regime trending)
    // Questo assicura sempre abbastanza dati per l'analisi adattiva
    int maxLag = (int)MathRound(barsAvailable * GetOrganicDecayPow(GetDefaultHurst(), 2.0));
    maxLag = MathMax(BOOTSTRAP_MIN_BARS / 2, maxLag);  // Minimo statistico
    
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
    // Quando scende sotto decay(H), il mercato ha "dimenticato"
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
        PrintFormat("[NATURAL] TF %s: varianza zero (prezzo flat) - TF DISABILITATO", EnumToString(tf));
        return result;
    }
    
    // ---------------------------------------------------------------
    // CALCOLA ESPONENTE DI HURST (per determinare peso TF)
    // Confrontato con g_hurstCenter e soglie dinamiche:
    //   H > g_hurstRandomHigh: trending  peso maggiore
    //   H < g_hurstRandomLow: mean-reverting  peso maggiore
    // 
    //  USA TUTTE LE BARRE COPIATE (rates[] gi disponibile)
    double hurstValue;
    if (copied >= 64) {  // Minimo assoluto per un calcolo H sensato
        hurstValue = CalculateHurstExponent(rates, copied);
        PrintFormat("[NATURAL] TF %s: H=%.3f calcolato su %d barre", 
            EnumToString(tf), hurstValue, copied);
    } else {
        PrintFormat("[NATURAL] TF %s: solo %d barre - insufficienti per H (minimo 64)", 
            EnumToString(tf), copied);
        hurstValue = GetDefaultHurst();  // Fallback
    }
    
    // Variabili per il calcolo del periodo naturale
    double autocorrSum = 0;
    int autocorrCount = 0;
    
    // Trova il lag dove l'autocorrelazione scende sotto decay(H)
    // Questo  il "periodo naturale" del mercato
    int naturalPeriod = 0;
    double threshold = GetOrganicDecay(g_hurstGlobal);  // ~0.62 per H=0.7 (soglia da Hurst!)
    double autocorrAtNaturalPeriod = 0;
    
    //  USA TUTTE LE BARRE DISPONIBILI per autocorrelazione (fino a maxLag)
    for (int lag = 1; lag < maxLag && lag < copied; lag++) {
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
                    PrintFormat("[NATURAL] TF %s: autocorr[%d]=%.3f < %.3f -> Periodo naturale=%d",
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
            // Derivato dalle barre disponibili: maxLag / 2
            naturalPeriod = maxLag / 2;
            PrintFormat("[NATURAL] TF %s: nessun decay trovato, uso maxLag/2=%d", 
                EnumToString(tf), naturalPeriod);
        }
    }
    
    //  Limita il periodo con proporzioni ragionevoli delle barre disponibili
    // minPeriod = 2  un requisito TECNICO (minimo per calcolare variazione)
    int minPeriod = 2;              // Requisito tecnico: servono almeno 2 punti
    int maxPeriod = maxLag / 2;     // Derivato dalle barre
    naturalPeriod = MathMax(minPeriod, MathMin(maxPeriod, naturalPeriod));
    
    // ---------------------------------------------------------------
    //  ESPONENTE DI HURST DETERMINA IL PESO TF
    // peso_TF = H_TF / (H_tutti_TF) - normalizzato
    // TF con H pi alto contribuiscono maggiormente
    // ---------------------------------------------------------------
    // FIX: Se Hurst non calcolabile, usa Hurst default ma mantieni TF valido (bootstrap)
    if (hurstValue < 0) {
        PrintFormat("[NATURAL] TF %s: Hurst non calcolabile (dati insufficienti) -> uso H default bootstrap", EnumToString(tf));
        hurstValue = GetDefaultHurst();
    }
    
    // VALIDATO: hurstValue gia' nel range [HURST_RANGE_MIN, HURST_RANGE_MAX]
    result.hurstExponent = hurstValue;
    //  MINIMO PERIODO: almeno BOOTSTRAP_MIN_BARS per stabilit
    result.period = MathMax(naturalPeriod, BOOTSTRAP_MIN_BARS);
    result.valid = true;
    
    //  AGGIORNA LOOKBACK ADATTIVO per il prossimo calcolo
    // lookback = periodo  scale(H) (memoria proporzionale al ciclo)
    double currentHurst = (result.hurstExponent > 0) ? result.hurstExponent : GetDefaultHurst();
    double memoryFactor = GetOrganicScalePow(currentHurst, 2.0);  // scale(H) = base^(2*H)
    int newLookback = (int)MathRound(result.period * memoryFactor);
    
    //  LIMITI EMPIRICI: minimo BOOTSTRAP_MIN_BARS2, massimo per evitare overflow
    newLookback = MathMax(BOOTSTRAP_MIN_BARS * 2, newLookback);
    newLookback = MathMin(newLookback, 512);  //  RIDOTTO da 2048 a 512 per stack safety
    
    //  Aggiorna lookback globale
    if (tf == PERIOD_M5) g_lookback_M5 = newLookback;
    else if (tf == PERIOD_H1) g_lookback_H1 = newLookback;
    else if (tf == PERIOD_H4) g_lookback_H4 = newLookback;
    else if (tf == PERIOD_D1) g_lookback_D1 = newLookback;
    
    if (shouldLog) {
        PrintFormat("[NATURAL] TF %s: Lookback aggiornato %d -> %d (periodo=%d, H=%.3f, memoria=%.2fx)",
            EnumToString(tf), initialLookback, newLookback, result.period, currentHurst, memoryFactor);
    }
    
    if (g_enableLogsEffective) {
        // NOTA: etichetta basata su soglie dinamiche se zona pronta, altrimenti solo valore H
        string regimeLabel = "WARM-UP";
        if (g_hurstZoneReady) {
            regimeLabel = (result.hurstExponent > g_hurstRandomHigh) ? "TRENDING" :
                         ((result.hurstExponent < g_hurstRandomLow) ? "MEAN-REV" : "RANDOM");
        }
        PrintFormat("[NATURAL] TF %s: Periodo=%d | Hurst=%.3f (%s)",
            EnumToString(tf), result.period, result.hurstExponent, regimeLabel);
    }
    
    return result;
}

//+------------------------------------------------------------------+
//| Trova il primo minimo locale dell'autocorrelazione            |
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
    
    //  USA TUTTO maxLag DISPONIBILE - no limiti arbitrari
    for (int lag = 2; lag < maxLag && lag < n; lag++) {
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
                    PrintFormat("[NATURAL] Minimo autocorr trovato a lag=%d (autocorr=%.3f)", 
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
//| CALCOLA PERCENTILE dai dati                                      |
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
//| CALCOLA MEDIANA                                                  |
//| Robusto agli outlier - ideale per regime RANDOM                  |
//+------------------------------------------------------------------+
double CalculateMedian(const double &arr[], int size)
{
    if (size <= 0) return 0;
    
    // Copia e ordina
    double sorted[];
    ArrayResize(sorted, size);
    for (int i = 0; i < size; i++) sorted[i] = arr[i];
    ArraySort(sorted);
    
    // Mediana
    if (size % 2 == 1) {
        return sorted[size / 2];
    } else {
        return (sorted[size / 2 - 1] + sorted[size / 2]) / 2.0;
    }
}

//+------------------------------------------------------------------+
//| CALCOLA MEDIA TRONCATA (Trimmed Mean)                            |
//| Scarta il 10% estremi - ideale per regime MEAN-REVERTING         |
//| Cattura il vero centro di oscillazione                           |
//+------------------------------------------------------------------+
double CalculateTrimmedMean(const double &arr[], int size, double trimPercent = -1.0)
{
    if (size <= 0) return 0;
    if (size < 5) return CalculateEmpiricalMean(arr, size);  // Fallback per pochi dati
    
    // Se trimPercent non passato, deriva da Hurst (decay)
    if (trimPercent < 0) trimPercent = GetOrganicDecayPow(GetDefaultHurst(), 2.0);
    
    // Copia e ordina
    double sorted[];
    ArrayResize(sorted, size);
    for (int i = 0; i < size; i++) sorted[i] = arr[i];
    ArraySort(sorted);
    
    // Calcola quanti elementi troncare da ogni lato
    int trimCount = (int)MathFloor(size * trimPercent);
    trimCount = MathMax(1, trimCount);  // Almeno 1 per lato
    
    // Verifica che rimangano abbastanza elementi
    int remaining = size - 2 * trimCount;
    if (remaining < 2) {
        trimCount = (size - 2) / 2;
        remaining = size - 2 * trimCount;
    }
    
    // Media dei valori centrali
    double sum = 0;
    for (int i = trimCount; i < size - trimCount; i++) {
        sum += sorted[i];
    }
    
    return sum / remaining;
}

//+------------------------------------------------------------------+
//| CALCOLA EMA (Exponential Moving Average)                         |
//| Dati recenti pesano di piu - ideale per regime TRENDING          |
//+------------------------------------------------------------------+
double CalculateEMA(const double &arr[], int size, double alpha)
{
    if (size <= 0) return 0;
    if (size == 1) return arr[0];
    
    // Limita alpha con margini empirici da range Hurst [0.1, 0.9]
    double alphaMin = HURST_RANGE_MIN / 10.0;  // 0.1/10 = 0.01
    double alphaMax = HURST_RANGE_MAX / (HURST_RANGE_MAX + 0.1);  // 0.9/1.0 = 0.9
    alpha = MathMax(alphaMin, MathMin(alphaMax, alpha));
    
    // EMA: inizia dal primo valore e procede verso il piu recente
    // arr[0] = piu vecchio, arr[size-1] = piu recente
    double ema = arr[0];
    for (int i = 1; i < size; i++) {
        ema = alpha * arr[i] + (1.0 - alpha) * ema;
    }
    
    return ema;
}

//+------------------------------------------------------------------+
//| CALCOLA CENTRO ADATTIVO HURST-DRIVEN con Smoothing               |
//|                                                                  |
//| SOGLIE 100% DATA-DRIVEN (non costanti 0.55/0.45!):              |
//| - center_H = media(H osservati) dalla storia                     |
//| - margin_H = stdev(H)  decay(H) - tutto dinamico               |
//|                                                                  |
//| TRENDING (H > center+margin):     EMA (recency bias)             |
//| RANDOM (centermargin):           Mediana (robustezza)           |
//| MEAN-REVERTING (H < center-margin): Trimmed Mean (oscillazione) |
//|                                                                  |
//| Smoothing: transizione graduale nelle zone di confine            |
//| - Evita discontinuita quando H attraversa le soglie              |
//| - Blend lineare tra metodi adiacenti                             |
//+------------------------------------------------------------------+
double CalculateAdaptiveCenter(const double &arr[], int size, double H)
{
    if (size <= 0) return 0;
    if (size < 4) return CalculateEmpiricalMean(arr, size);  // Fallback per pochi dati
    
    // SOGLIE DI REGIME DERIVATE DAL CENTRO HURST EMPIRICO
    // Invece di usare 0.40, 0.45, 0.55, 0.60 fissi, deriviamo da g_hurstCenter +- margine
    double center_H = g_hurstZoneReady ? g_hurstCenter : GetDefaultHurst();  // Centro empirico
    // Margine fallback = decay(H) tipico, non 0.2 fisso
    double margin_H = g_hurstZoneReady ? g_hurstZoneMargin : GetOrganicDecayPow(GetDefaultHurst(), 2.0);
    
    // Soglie derivate con decay(H) invece di 0.5 fisso per transizioni
    double decayH = GetOrganicDecay(H);  // Usa H parameter, non GetDefaultHurst() fisso!
    double H_TRENDING_HIGH = center_H + margin_H;              // Limite superiore zona random
    double H_TRENDING_LOW = center_H + margin_H * decayH;      // Inizio transizione trending
    double H_REVERTING_HIGH = center_H - margin_H * decayH;    // Fine transizione reverting
    double H_REVERTING_LOW = center_H - margin_H;              // Limite inferiore zona random
    
    //  Clamp alle soglie basate su limiti EMPIRICI (GetHurstMin/Max)
    // Valida che le soglie non superino i limiti osservati, mantenendo la loro definizione matematica
    double clampMin = GetHurstMin();  // Min osservato
    double clampMax = GetHurstMax();  // Max osservato
    // H_TRENDING_HIGH = center + margin: valida che sia <= clampMax
    H_TRENDING_HIGH = MathMin(clampMax, H_TRENDING_HIGH);
    // H_TRENDING_LOW = center + margin*decay: valida che sia >= clampMin e <= H_TRENDING_HIGH
    H_TRENDING_LOW = MathMax(clampMin, MathMin(H_TRENDING_HIGH, H_TRENDING_LOW));
    // H_REVERTING_HIGH = center - margin*decay: valida che sia >= H_REVERTING_LOW e <= clampMax
    H_REVERTING_HIGH = MathMin(clampMax, MathMax(H_REVERTING_LOW, H_REVERTING_HIGH));
    // H_REVERTING_LOW = center - margin: valida che sia >= clampMin
    H_REVERTING_LOW = MathMax(clampMin, H_REVERTING_LOW);
    
    // Pre-calcola tutti i centri (alcuni potrebbero non servire, ma sono veloci)
    double decay = GetOrganicDecay(H);
    double alpha = decay;  // alpha = 2^(-H) ~ 0.6-0.7 per H tipico
    
    double centerEMA = CalculateEMA(arr, size, alpha);
    double centerMedian = CalculateMedian(arr, size);
    //  trimPercent = decay(H) ~ 0.25 per H=0.5 (data-driven, elimina outliers)
    double trimPercent = GetOrganicDecayPow(H, 2.0);
    double centerTrimmed = CalculateTrimmedMean(arr, size, trimPercent);
    
    double center = 0;
    
    // 
    // ZONA TRENDING PURO (H >= H_TRENDING_HIGH)
    // 
    if (H >= H_TRENDING_HIGH) {
        center = centerEMA;
    }
    // 
    // ZONA TRANSIZIONE TRENDINGRANDOM (H_TRENDING_LOW <= H < H_TRENDING_HIGH)
    // Blend lineare: EMA  Mediana
    // 
    else if (H >= H_TRENDING_LOW) {
        double range = H_TRENDING_HIGH - H_TRENDING_LOW;
        //  Peso fallback: decay(H) se range ~0 (adattivo, non 0.5 fisso)
        double weight_ema = (range > 0.001) ? (H - H_TRENDING_LOW) / range : decayH;
        center = weight_ema * centerEMA + (1.0 - weight_ema) * centerMedian;
    }
    // 
    // ZONA RANDOM PURA (H_REVERTING_HIGH <= H < H_TRENDING_LOW)
    // 
    else if (H >= H_REVERTING_HIGH) {
        center = centerMedian;
    }
    // 
    // ZONA TRANSIZIONE RANDOMREVERTING (H_REVERTING_LOW <= H < H_REVERTING_HIGH)
    // Blend lineare: Mediana  Trimmed Mean
    // 
    else if (H >= H_REVERTING_LOW) {
        double range = H_REVERTING_HIGH - H_REVERTING_LOW;
        //  Peso fallback: decay(H) se range ~0 (adattivo, non 0.5 fisso)
        double weight_median = (range > 0.001) ? (H - H_REVERTING_LOW) / range : decayH;
        center = weight_median * centerMedian + (1.0 - weight_median) * centerTrimmed;
    }
    // 
    // ZONA MEAN-REVERTING PURA (H < H_REVERTING_LOW)
    // 
    else {
        center = centerTrimmed;
    }
    
    return center;
}

//+------------------------------------------------------------------+
//| CALCOLA MEDIA EMPIRICA (mantenuta per retrocompatibilita)        |
//| Ritorna: mean(arr) = somma(valori) / N                           |
//+------------------------------------------------------------------+
double CalculateEmpiricalMean(const double &arr[], int size)
{
    if (size <= 0) return 0;
    
    double sum = 0;
    for (int i = 0; i < size; i++) sum += arr[i];
    return sum / size;
}

//+------------------------------------------------------------------+
//| CALCOLA DEVIAZIONE STANDARD                                      |
//| La scala REALE dipende dalla volatilita storica dell'indicatore  |
//+------------------------------------------------------------------+
double CalculateEmpiricalStdDev(const double &arr[], int size, double mean)
{
    // PURO: ritorna 0 se dati insufficienti - il chiamante gestira l'errore
    if (size <= 1) return 0.0;
    
    double sumSq = 0;
    for (int i = 0; i < size; i++) {
        double diff = arr[i] - mean;
        sumSq += diff * diff;
    }
    return MathSqrt(sumSq / (size - 1));
}

//+------------------------------------------------------------------+
//| CALCOLA SOGLIE EMPIRICHE per un TimeFrame - HURST-ADATTIVO       |
//| Tutti i centri e scale derivano dai DATI storici reali           |
//| Centro calcolato con metodo adattivo al regime Hurst:            |
//|   TRENDING (H>0.55):     EMA (recency)                           |
//|   RANDOM (0.45-0.55):    Mediana (robustezza)                    |
//|   REVERTING (H<0.45):    Trimmed Mean (centro vero)              |
//| Se i dati sono insufficienti, INVALIDA il TF (no fallback!)      |
//| Ritorna: true se calcolo OK, false se dati insufficienti         |
//+------------------------------------------------------------------+
bool CalculateEmpiricalThresholds(TimeFrameData &data, int lookback)
{
    int size = ArraySize(data.rsi);
    //  USA TUTTI I DATI DISPONIBILI - no limite lookback arbitrario
    int n = size;
    
    // MINIMO: periodo  decay(H) (data-driven)
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    int minBarsRequired = MathMax(4, (int)MathRound(basePeriod * GetOrganicDecayPow(GetDefaultHurst(), 2.0)));
    
    if (n < minBarsRequired) {
        // DATI INSUFFICIENTI - NON USARE FALLBACK, INVALIDA IL TF
        Print("[EMPIRICAL] DATI INSUFFICIENTI! Richieste almeno ", minBarsRequired, 
              " barre, disponibili: ", n, " - TF DISABILITATO");
        
        // Azzera tutto per evitare uso accidentale
        data.rsi_center = 0;
        data.rsi_scale = 0;
        data.adx_p25 = 0;
        data.adx_p75 = 0;
        
        return false;  // Segnala fallimento
    }
    
    // ---------------------------------------------------------------
    // CENTRI ADATTIVI HURST-DRIVEN con Smoothing
    // Il metodo di stima cambia in base al regime di mercato
    // ---------------------------------------------------------------
    
    // RSI: prepara array delle ultime n barre
    double rsi_data[];
    ArrayResize(rsi_data, n);
    for (int i = 0; i < n; i++) rsi_data[i] = data.rsi[size - n + i];
    
    // NUOVO: Centro adattivo invece di media semplice
    data.rsi_center = CalculateAdaptiveCenter(rsi_data, n, g_hurstGlobal);
    
    // StdDev calcolata rispetto al centro adattivo
    double rsi_stdev = CalculateEmpiricalStdDev(rsi_data, n, data.rsi_center);
    if (rsi_stdev <= 0) {
        Print("[EMPIRICAL] RSI stdev=0, dati flat - TF DISABILITATO");
        return false;
    }
    data.rsi_scale = rsi_stdev * GetOrganicScale(g_hurstGlobal);  // Scala = stdev * 2^H
    
    // ---------------------------------------------------------------
    // ADX PERCENTILI - Soglie dalla distribuzione REALE con Hurst
    // ---------------------------------------------------------------
    if (ArraySize(data.adx) >= n) {
        double adx_data[];
        ArrayResize(adx_data, n);
        for (int i = 0; i < n; i++) adx_data[i] = data.adx[size - n + i];
        
        // Verifica che ADX abbia varianza (non tutti valori identici)
        double adx_min = adx_data[0], adx_max = adx_data[0];
        for (int i = 1; i < n; i++) {
            if (adx_data[i] < adx_min) adx_min = adx_data[i];
            if (adx_data[i] > adx_max) adx_max = adx_data[i];
        }
        double adx_range = adx_max - adx_min;
        if (adx_range < 0.1) {  // ADX piatto o quasi (< 0.1 punti di variazione)
            // Log warning per debug
            if (g_enableLogsEffective) {
                PrintFormat("[ADX EMPIRICAL] WARN: dati piatti rilevati: range=%.3f < 0.1 | Fallback: min=%.1f max=%.1f",
                    adx_range, adx_min, adx_max);
            }
            Print("[EMPIRICAL] ADX flat (range < 0.1) - TF usa fallback bootstrap");
            // Usa valori bootstrap approssimati invece di disabilitare
            data.adx_p25 = adx_min + adx_range * 0.25;
            data.adx_p75 = adx_min + adx_range * 0.75;
            if (data.adx_p75 <= data.adx_p25) {
                data.adx_p75 = data.adx_p25 + 1.0;  // Garantisce p75 > p25
            }
        } else {
            // Percentili adattivi attorno a 25 e 75, modulati da Hurst
            // H trending (>0.5)  range pi stretto (es. 30-70)
            // H random (=0.5)  range standard (25-75)
            // H mean-rev (<0.5)  range pi largo (es. 20-80)
            double hurstDev = (g_hurstGlobal - 0.5) * 20.0;  // 10 max per H in [0,1]
            double p_low = MathMax(10.0, MathMin(40.0, 25.0 + hurstDev));   // Range [10, 40]
            double p_high = MathMax(60.0, MathMin(90.0, 75.0 + hurstDev));  // Range [60, 90]
            
            data.adx_p25 = CalculatePercentile(adx_data, n, p_low);   // ~25 percentile (Hurst-adaptive)
            data.adx_p75 = CalculatePercentile(adx_data, n, p_high);  // ~75 percentile (Hurst-adaptive)
            
            // Verifica finale (dovrebbe sempre passare con p_low < p_high)
            if (data.adx_p75 <= data.adx_p25) {
                PrintFormat("[EMPIRICAL] ADX percentili ancora invalidi dopo calcolo (p25=%.2f p75=%.2f) - usa fallback",
                    data.adx_p25, data.adx_p75);
                data.adx_p75 = data.adx_p25 + 1.0;  // Garantisce p75 > p25
            }
        }
    } else {
        Print("[EMPIRICAL] ADX: dati insufficienti");
        return false;
    }
    
    // ---------------------------------------------------------------
    // FIX: OBV SCALA EMPIRICA - Dalle variazioni REALI
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
        
        // Scala = stdev * scale(H), con fallback se troppo piccola
        if (obv_change_stdev > 0) {
            data.obv_scale = obv_change_stdev * GetOrganicScale(g_hurstGlobal);
        } else {
            // FIX: Fallback migliorato - usa range OBV osservato
            double obv_max = data.obv[startIdx];
            double obv_min = data.obv[startIdx];
            for (int i = 1; i < n; i++) {
                if (data.obv[startIdx + i] > obv_max) obv_max = data.obv[startIdx + i];
                if (data.obv[startIdx + i] < obv_min) obv_min = data.obv[startIdx + i];
            }
            double obv_range = obv_max - obv_min;
            // Scala = range / (scale(H)^2 * sqrt(n)) - derivato da Hurst!
            double hScale = GetOrganicScale(g_hurstGlobal);  // 2^H
            double divisor = hScale * hScale * MathSqrt((double)n);  // scale^2 * sqrt(n)
            if (divisor > 0 && obv_range > 0) {
                data.obv_scale = obv_range / divisor;
            } else {
                // FIX: Fallback = 128 (potenza di 2 coerente)
                data.obv_scale = GetBufferHuge();  // 128
            }
        }
        // FIX: Garantire sempre scala minima positiva per evitare DIV/0
        if (data.obv_scale <= 0) {
            data.obv_scale = GetBufferLarge();  // Minimo = 32
        }
    } else {
        // OBV non disponibile, usa fallback
        data.obv_scale = GetBufferHuge();  // 128 (valore tipico per volumi)
    }
    
    if (g_enableLogsEffective) {
        // Determina quale metodo e stato usato per il centro
        //  Soglie derivate da g_hurstCenter  g_hurstZoneMargin CON decay(H)
        double center_H = g_hurstZoneReady ? g_hurstCenter : GetDefaultHurst();
        double margin_H = g_hurstZoneReady ? g_hurstZoneMargin : GetOrganicDecayPow(GetDefaultHurst(), 2.0);
        double decayH = GetOrganicDecay(GetDefaultHurst());  // Data-driven (non 0.5 fisso!)
        double H_TRENDING_HIGH = center_H + margin_H;
        double H_TRENDING_LOW = center_H + margin_H * decayH;
        double H_REVERTING_HIGH = center_H - margin_H * decayH;
        double H_REVERTING_LOW = center_H - margin_H;
        
        string centerMethod;
        if (g_hurstGlobal >= H_TRENDING_HIGH) centerMethod = "EMA";
        else if (g_hurstGlobal >= H_TRENDING_LOW) centerMethod = "EMA+MED";
        else if (g_hurstGlobal >= H_REVERTING_HIGH) centerMethod = "MEDIAN";
        else if (g_hurstGlobal >= H_REVERTING_LOW) centerMethod = "MED+TRIM";
        else centerMethod = "TRIMMED";
        
        PrintFormat("[EMPIRICAL] RSI center=%.1f (%s) scale=%.1f | H=%.3f | ADX p25=%.1f p75=%.1f | OBV scale=%.1f",
            data.rsi_center, centerMethod, data.rsi_scale, g_hurstGlobal, data.adx_p25, data.adx_p75, data.obv_scale);
    }
    
    return true;  // Calcolo completato con successo
}

//+------------------------------------------------------------------+
//|  CALCOLA PERIODI 100% DATA-DRIVEN                              |
//| TUTTO derivato dal periodo naturale usando SCALE 2^H              |
//| NESSUNA costante a priori - tutto dall'Hurst exponent            |
//| scale = 2^H, decay = 2^(-H) - derivati dal regime di mercato     |
//| PESO TF: derivato dall'ESPONENTE DI HURST!                       |
//+------------------------------------------------------------------+
void CalculateOrganicPeriodsFromData(ENUM_TIMEFRAMES tf, OrganicPeriods &organic, int naturalPeriod, double weight, double hurstExp)
{
    //  PESO E HURST passati dal chiamante (derivati empiricamente)
    organic.weight = weight;
    organic.hurstExponent = hurstExp;
    
    // ---------------------------------------------------------------
    //  SCALE DINAMICHE DERIVATE DA HURST
    // scale = 2^H    (fattore di espansione)
    // decay = 2^(-H) (fattore di contrazione)
    //
    // Per H=0.5 (random): scale=21.414, decay0.707
    // Per H=0.7 (trend):  scale1.625, decay0.616
    // Per H=0.3 (MR):     scale1.231, decay0.812
    // ---------------------------------------------------------------
    double H = (hurstExp > 0) ? hurstExp : g_hurstGlobal;
    double scale = GetOrganicScale(H);
    double decay = GetOrganicDecay(H);
    double scale2 = GetOrganicScalePow(H, 2.0);  // scale = 2^(2H)
    double scale3 = GetOrganicScalePow(H, 3.0);  // scale = 2^(3H)
    double decay2 = GetOrganicDecayPow(H, 2.0);  // decay = 2^(-2H)
    double decay3 = GetOrganicDecayPow(H, 3.0);  // decay = 2^(-3H)
    double decay4 = GetOrganicDecayPow(H, 4.0);  // decay = 2^(-4H)
    
    // Salva scale nel struct per uso successivo
    organic.scale = scale;
    organic.decay = decay;
    
    // ---------------------------------------------------------------
    //  PERIODO NATURALE = deriva dall'AUTOCORRELAZIONE (dai DATI!)
    // Tutti gli altri periodi sono DERIVATI da questo usando scale 2^H
    // Nessun numero arbitrario - la base viene dal mercato stesso
    // ---------------------------------------------------------------
    double base = (double)naturalPeriod;
    
    // ---------------------------------------------------------------
    //  PERIODI DERIVATI DA SCALE 2^H
    // Ogni indicatore usa un multiplo/divisore scale del periodo naturale
    // Questo crea una scala ADATTIVA che dipende dal regime di mercato
    //
    // Molto veloce = base  decay = base  2^(-2H)
    // Veloce       = base  decay  = base  2^(-H)
    // Medio        = base  1       (periodo naturale)
    // Lento        = base  scale  = base  2^H
    // Molto lento  = base  scale = base  2^(2H)
    // Lunghissimo  = base  scale = base  2^(3H)
    // ---------------------------------------------------------------
    
    //  Periodi organici - TUTTI derivati dal periodo naturale e H
    // Minimi statistici da BOOTSTRAP_MIN_BARS (non arbitrari):
    // - EMA/RSI: minimo BOOTSTRAP_MIN_BARS/4 (2) per convergere
    // - MACD/Stoch: minimo BOOTSTRAP_MIN_BARS/2 (4) per segnali stabili
    // - Trend indicators: minimo BOOTSTRAP_MIN_BARS2 (16) per filtrare rumore
    int veryFast = (int)MathMax(BOOTSTRAP_MIN_BARS / 4, MathRound(base * decay2));   // min=2, base  decay
    int fast     = (int)MathMax(BOOTSTRAP_MIN_BARS / 3, MathRound(base * decay));    // min=3, base  decay
    int medium   = (int)MathMax(BOOTSTRAP_MIN_BARS / 3, MathRound(base));            // min=3, base (naturale)
    int slow     = (int)MathMax(BOOTSTRAP_MIN_BARS / 2, MathRound(base * scale));    // min=4, base  scale
    int verySlow = (int)MathMax(BOOTSTRAP_MIN_BARS, MathRound(base * scale2));       // min=8, base  scale
    int longest  = (int)MathMax(BOOTSTRAP_MIN_BARS * 2, MathRound(base * scale3));   // min=16, base  scale
    
    if (g_enableLogsEffective) {
        PrintFormat("[ORGANIC] TF %s: H=%.3f scale=%.3f decay=%.3f | Natural=%d -> VeryFast=%d Fast=%d Medium=%d Slow=%d VerySlow=%d Longest=%d",
            EnumToString(tf), H, scale, decay, naturalPeriod, veryFast, fast, medium, slow, verySlow, longest);
    }
    
    // ---------------------------------------------------------------
    //  ASSEGNAZIONE PERIODI - Logica basata sul ruolo dell'indicatore
    // Indicatori "veloci"  usano periodi corti (momentum, segnali)
    // Indicatori "lenti"  usano periodi lunghi (trend, struttura)
    // ---------------------------------------------------------------
    
    // Trend indicators (necessitano periodi pi lunghi)
    organic.ema = slow;                     // EMA: segue il trend  slow
    
    // Momentum indicators
    organic.rsi = medium;                   // RSI  medium
    
    // MACD (tre periodi in relazione scale tra loro)
    organic.macd_fast = fast;               // MACD veloce  fast
    organic.macd_slow = slow;               // MACD lento  slow
    organic.macd_signal = veryFast;         // MACD signal  veryFast (smoothing)
    
    // Bollinger Bands
    organic.bb = slow;                      // BB periodo  slow
    // BB deviation: decay + base  decay (data-driven)
    organic.bb_dev = decay + MathSqrt(base) * decay2;
    // Limiti: min=decay (0.6-0.8), max=scale (2-3)
    organic.bb_dev = MathMax(decay, MathMin(scale2, organic.bb_dev));
    
    // Volatility indicators
    organic.atr = medium;                   // ATR: volatilit  medium
    organic.adx = medium;                   // ADX: forza trend  medium
    
    // ---------------------------------------------------------------
    //  INDICATORI TREND (derivati da scale 2^H)
    // ---------------------------------------------------------------
    
    // Parabolic SAR (parametri step/max derivati da H)
    organic.psar_step = decay4;             // decay  0.05-0.25 (step dinamico)
    organic.psar_max = decay;               // decay  0.6-0.8 (max dinamico)
    
    // SMA Cross (due medie in rapporto scale tra loro)
    organic.sma_fast = slow;                // SMA veloce = base  scale
    organic.sma_slow = longest;             // SMA lenta = base  scale
    
    // Ichimoku (tre linee in rapporto scale tra loro)
    organic.ichimoku_tenkan = medium;       // Tenkan = base (conversione veloce)
    organic.ichimoku_kijun = slow;          // Kijun = base  scale (linea base)
    organic.ichimoku_senkou = verySlow;     // Senkou B = base  scale (cloud trailing)
    
    // ---------------------------------------------------------------
    //  STOCHASTIC (indicatore mean-reversion, vota inversione)
    // Periodi derivati da scale, usato per rilevare zone ipercomprato/ipervenduto
    // ---------------------------------------------------------------
    organic.stoch_k = medium;               // %K = periodo naturale
    organic.stoch_d = fast;                 // %D = periodo  decay (pi veloce)
    organic.stoch_slowing = (int)MathMax(2, MathRound(scale));  // Slowing  2-3
    
    // ---------------------------------------------------------------
    //  PESO TF = H_TF / (H_tutti_TF)
    // TF con Hurst maggiore  peso maggiore
    // peso gi calcolato in OnInit e assegnato a organic.weight
    // ---------------------------------------------------------------
    // organic.weight gi assegnato all'inizio della funzione
    // organic.hurstExponent gi assegnato all'inizio della funzione
    
    //  Barre minime = periodo pi lungo usato  scale + margin
    // Calcolato dinamicamente in base ai periodi effettivi
    organic.min_bars_required = (int)MathRound(longest * scale) + medium;
    
    //  Salva il periodo naturale per uso nelle scale
    organic.naturalPeriod = naturalPeriod;
}

//+------------------------------------------------------------------+
//|  Log dei periodi organici calcolati                            |
//+------------------------------------------------------------------+
void LogOrganicPeriods(string tfName, OrganicPeriods &organic)
{
    PrintFormat("[%s] H=%.3f scale=%.3f decay=%.3f | Peso TF: %.2f",
        tfName, organic.hurstExponent, organic.scale, organic.decay, organic.weight);
    PrintFormat("[%s] Periodi: EMA=%d RSI=%d MACD=%d/%d/%d BB=%d(%.2f) ATR=%d ADX=%d",
        tfName, organic.ema, organic.rsi, 
        organic.macd_fast, organic.macd_slow, organic.macd_signal,
        organic.bb, organic.bb_dev, organic.atr, organic.adx);
    PrintFormat("[%s] TREND: PSAR=%.4f/%.3f SMA=%d/%d Ichimoku=%d/%d/%d | Stoch=%d/%d/%d | Min barre: %d",
        tfName, organic.psar_step, organic.psar_max,
        organic.sma_fast, organic.sma_slow,
        organic.ichimoku_tenkan, organic.ichimoku_kijun, organic.ichimoku_senkou,
        organic.stoch_k, organic.stoch_d, organic.stoch_slowing,
        organic.min_bars_required);
}

//+------------------------------------------------------------------+
//|  FIX: Verifica se i periodi sono cambiati significativamente    |
//| Ritorna true se almeno un periodo  cambiato > decay(H)          |
//| In tal caso gli handle indicatori devono essere ricreati          |
//+------------------------------------------------------------------+
bool PeriodsChangedSignificantly()
{
    if (!g_periodsInitialized) return false;  // Primo calcolo, non serve confronto
    
    //  DATA-DRIVEN: Soglia cambio = decay(H) = 2^(-H) (persistenza sistema)
    //    Per H=0.5  decay0.707 = 70.7% (molto conservativo)
    //    Per H=0.7  decay0.616 = 61.6% (trending, meno sensibile)
    //    Per H=0.3  decay0.812 = 81.2% (mean-reverting, pi sensibile)
    double changeThreshold = GetOrganicDecay(g_hurstGlobal);
    
    // Controlla ogni TF attivo
    if (g_dataReady_M5) {
        double oldPeriod = (double)g_prevOrganic_M5.ema;
        double newPeriod = (double)g_organic_M5.ema;
        if (oldPeriod > 0 && MathAbs(newPeriod - oldPeriod) / oldPeriod > changeThreshold) {
            if (g_enableLogsEffective) {
                PrintFormat("[PERIODS] M5 EMA period changed: %d -> %d (%.1f%%)",
                    (int)oldPeriod, (int)newPeriod, 100.0 * MathAbs(newPeriod - oldPeriod) / oldPeriod);
            }
            return true;
        }
    }
    
    if (g_dataReady_H1) {
        double oldPeriod = (double)g_prevOrganic_H1.ema;
        double newPeriod = (double)g_organic_H1.ema;
        if (oldPeriod > 0 && MathAbs(newPeriod - oldPeriod) / oldPeriod > changeThreshold) {
            if (g_enableLogsEffective) {
                PrintFormat("[PERIODS] H1 EMA period changed: %d -> %d (%.1f%%)", 
                    (int)oldPeriod, (int)newPeriod, 100.0 * MathAbs(newPeriod - oldPeriod) / oldPeriod);
            }
            return true;
        }
    }
    
    if (g_dataReady_H4) {
        double oldPeriod = (double)g_prevOrganic_H4.ema;
        double newPeriod = (double)g_organic_H4.ema;
        if (oldPeriod > 0 && MathAbs(newPeriod - oldPeriod) / oldPeriod > changeThreshold) {
            if (g_enableLogsEffective) {
                PrintFormat("[PERIODS] H4 EMA period changed: %d -> %d (%.1f%%)", 
                    (int)oldPeriod, (int)newPeriod, 100.0 * MathAbs(newPeriod - oldPeriod) / oldPeriod);
            }
            return true;
        }
    }
    
    if (g_dataReady_D1) {
        double oldPeriod = (double)g_prevOrganic_D1.ema;
        double newPeriod = (double)g_organic_D1.ema;
        if (oldPeriod > 0 && MathAbs(newPeriod - oldPeriod) / oldPeriod > changeThreshold) {
            if (g_enableLogsEffective) {
                PrintFormat("[PERIODS] D1 EMA period changed: %d -> %d (%.1f%%)", 
                    (int)oldPeriod, (int)newPeriod, 100.0 * MathAbs(newPeriod - oldPeriod) / oldPeriod);
            }
            return true;
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| FIX: Salva periodi correnti come precedenti                       |
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
        PrintFormat("[DEINIT] EA Deinit avviato - Motivo: %d (%s)", reason, GetDeinitReasonText(reason));
    }
    
    // ---------------------------------------------------------------
    // REPORT FINALE STATISTICHE TRADING
    // ---------------------------------------------------------------
    if (g_stats.totalTrades > 0) {
        double netProfit = g_stats.totalProfit - g_stats.totalLoss;
        double winRate = 100.0 * g_stats.winTrades / g_stats.totalTrades;
        double avgSlippage = (g_stats.slippageCount > 0) ? g_stats.totalSlippage / g_stats.slippageCount : 0;
        
        Print("");
        Print("+---------------------------------------------------------------------------+");
        Print("REPORT FINALE SESSIONE");
        Print("---------------------------------------------------------------------------");
        PrintFormat("Simbolo: %s | Magic: %d", _Symbol, g_uniqueMagicNumber);
        PrintFormat("Periodo: %s -> %s", 
            TimeToString(g_eaStartTime, TIME_DATE|TIME_MINUTES),
            TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
        Print("---------------------------------------------------------------------------");
        PrintFormat("TRADES: %d totali | Win: %d (%.1f%%) | Loss: %d (%.1f%%)",
            g_stats.totalTrades,
            g_stats.winTrades, winRate,
            g_stats.lossTrades, 100.0 - winRate);
        PrintFormat("PROFITTO LORDO: +%.2f | PERDITA LORDA: -%.2f",
            g_stats.totalProfit, g_stats.totalLoss);
        PrintFormat("PROFITTO NETTO: %+.2f %s",
            netProfit, AccountInfoString(ACCOUNT_CURRENCY));
        PrintFormat("COMMISSIONI: %.2f | SWAP: %.2f",
            g_stats.totalCommission, g_stats.totalSwap);
        Print("---------------------------------------------------------------------------");
        PrintFormat("PROFIT FACTOR: %.2f", g_stats.profitFactor);
        PrintFormat("EXPECTANCY: %.2f per trade", g_stats.expectancy);
        PrintFormat("AVG WIN: %.2f | AVG LOSS: %.2f | Ratio: %.2f",
            g_stats.avgWin, g_stats.avgLoss,
            g_stats.avgLoss > 0 ? g_stats.avgWin / g_stats.avgLoss : 0);
        Print("---------------------------------------------------------------------------");
        PrintFormat("MAX DRAWDOWN: %.2f (%.2f%%)",
            g_stats.maxDrawdown, g_stats.maxDrawdownPct);
        PrintFormat("MAX WIN STREAK: %d | MAX LOSS STREAK: %d",
            g_stats.maxWinStreak, g_stats.maxLossStreak);
        if (g_stats.slippageCount > 0) {
            PrintFormat("AVG SLIPPAGE: %.2f pts su %d trade",
                avgSlippage, g_stats.slippageCount);
        }
        Print("+---------------------------------------------------------------------------+");
        Print("");
    } else {
        Print("[DEINIT] Nessun trade eseguito in questa sessione");
    }
    
    // ---------------------------------------------------------------
    // EXPORT TRADES PER MONTE CARLO ANALYSIS
    // ---------------------------------------------------------------
    if (ExportTradesCSV) {
        Print("[DEINIT] Avvio esportazione trade CSV...");
        ExportTradesToCSV();
    } else {
        Print("[DEINIT] Export CSV disabilitato (ExportTradesCSV=false)");
    }

    // ---------------------------------------------------------------
    // EXPORT ESTESO (secondo file, non rompe montecarlo_analyzer.py)
    // ---------------------------------------------------------------
    if (ExportExtendedTradesCSV) {
        Print("[DEINIT] Avvio esportazione trade CSV esteso...");
        ExportExtendedTradesToCSV();
    } else {
        Print("[DEINIT] Export CSV esteso disabilitato (ExportExtendedTradesCSV=false)");
    }
    
    EventKillTimer();
    if (g_enableLogsEffective) Print("[DEINIT] Timer terminato");
    
    ReleaseIndicators();
    
    // Reset buffer storici (pulizia esplicita)
    int hurstSize = ArraySize(g_hurstHistory);
    int scoreSize = ArraySize(g_scoreHistory);
    int tradeScoreSize = ArraySize(g_tradeScoreHistory);
    
    ArrayFree(g_hurstHistory);
    ArrayFree(g_scoreHistory);
    ArrayFree(g_tradeScoreHistory);
    
    // Reset indici buffer
    g_hurstHistorySize = 0;
    g_hurstHistoryIndex = 0;
    g_scoreHistorySize = 0;
    g_scoreHistoryIndex = 0;
    g_tradeScoreHistorySize = 0;
    g_tradeScoreHistoryIndex = 0;
    
    // Reset somme incrementali (CRITICO per riavvio EA!)
    g_hurstSum = 0.0;
    g_hurstSumSq = 0.0;
    g_scoreSum = 0.0;
    g_scoreSumSq = 0.0;
    g_tradeScoreSum = 0.0;
    g_tradeScoreSumSq = 0.0;
    
    // FIX: Reset contatori anti-drift
    g_hurstOperationCount = 0;
    g_scoreOperationCount = 0;
    g_tradeScoreOperationCount = 0;
    
    // Reset flag di stato
    g_hurstZoneReady = false;
    g_hurstReady = false;
    g_tradeScoreReady = false;
    g_scoreThresholdReady = false;
    
    // Reset variabili di cache e contatori
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
        PrintFormat("[DEINIT-BUFFER] g_hurstHistory liberato: %d elementi -> 0 %s",
            hurstSize, ArraySize(g_hurstHistory) == 0 ? "OK" : "ERRORI");
        PrintFormat("[DEINIT-BUFFER] g_scoreHistory liberato: %d elementi -> 0 %s",
            scoreSize, ArraySize(g_scoreHistory) == 0 ? "OK" : "ERRORI");
        PrintFormat("[DEINIT-BUFFER] g_tradeScoreHistory liberato: %d elementi -> 0 %s",
            tradeScoreSize, ArraySize(g_tradeScoreHistory) == 0 ? "OK" : "ERRORI");
        Print("[DEINIT] EA terminato correttamente");
    }
}

//+------------------------------------------------------------------+
//| EXPORT TRADES TO CSV - Per analisi Monte Carlo                |
//| Esporta tutti i trade chiusi in formato CSV per Python           |
//| Funziona sia in LIVE che in BACKTEST                          |
//+------------------------------------------------------------------+
void ExportTradesToCSV()
{
    bool isTester = MQLInfoInteger(MQL_TESTER) != 0;
    Print(isTester ? "[EXPORT] Modalita BACKTEST" : "[EXPORT] Modalita LIVE");
    
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
    PrintFormat("[EXPORT] HistoryDealsTotal = %d", totalDeals);
    if (totalDeals == 0) {
        Print("[EXPORT] Nessun deal nello storico - nessun file creato");
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
        Print("[EXPORT] Nessun trade valido trovato per questo simbolo/EA");
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
    // APRI FILE - Usa FILE_COMMON per accessibilita'
    // ---------------------------------------------------------------
    // FILE_COMMON salva in: C:\Users\[User]\AppData\Roaming\MetaQuotes\Terminal\Common\Files
    // Questo e' accessibile sia da live che da tester
    bool wroteToCommon = true;
    int fileHandle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ';');
    
    if (fileHandle == INVALID_HANDLE) {
        // Fallback: prova senza FILE_COMMON
        wroteToCommon = false;
        fileHandle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI, ';');
        if (fileHandle == INVALID_HANDLE) {
            PrintFormat("[EXPORT] Impossibile creare file: %s (Errore: %d)", filename, GetLastError());
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
                    // Aggiungi commissione di apertura SOLO se presente e non gia' inclusa
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
        
        // Il TIPO della posizione e' quello del deal di APERTURA (non chiusura!)
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
        string actualPath = wroteToCommon ? commonPath : localPath;
        
        Print("");
        Print("+---------------------------------------------------------------------------+");
        Print("EXPORT TRADE COMPLETATO PER MONTE CARLO");
        Print("---------------------------------------------------------------------------");
        PrintFormat("Trade esportati: %d", exportedCount);
        PrintFormat("Balance iniziale: %.2f -> Balance finale: %.2f", startBalance, runningBalance);
        PrintFormat("Profitto totale: %+.2f", totalPL);
        Print("---------------------------------------------------------------------------");
        PrintFormat("File: %s", filename);
        PrintFormat("Salvato in (%s):", wroteToCommon ? "COMMON" : "LOCALE");
        PrintFormat("   %s", actualPath);
        Print("---------------------------------------------------------------------------");
        Print("Per analisi Monte Carlo:");
        Print("   1. Copia il file nella cartella montecarlo/");
        Print("   2. Esegui: python example_usage.py");
        Print("+---------------------------------------------------------------------------+");
        Print("");
    } else {
        Print("[EXPORT] Nessun trade esportato");
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
//| Inizializzazione handles indicatori con periodi ORGANICI         |
//+------------------------------------------------------------------+
bool InitializeIndicators()
{
    if (g_enableLogsEffective) Print("[INIT-HANDLES] Inizio creazione handle indicatori...");
    
    int handleCount = 0;
    int handleErrors = 0;
    
    // ---------------------------------------------------------------
    // M5: Timeframe operativo (scalping/intraday)
    // FIX: crea handle solo se TF data-ready (parametri organici validi)
    // ---------------------------------------------------------------
    if (g_dataReady_M5) {
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
    } else {
        emaHandle_M5 = INVALID_HANDLE; macdHandle_M5 = INVALID_HANDLE; psarHandle_M5 = INVALID_HANDLE;
        smaFastHandle_M5 = INVALID_HANDLE; smaSlowHandle_M5 = INVALID_HANDLE; ichimokuHandle_M5 = INVALID_HANDLE;
        adxHandle_M5 = INVALID_HANDLE; bbHandle_M5 = INVALID_HANDLE; obvHandle_M5 = INVALID_HANDLE;
        atrHandle_M5 = INVALID_HANDLE; rsiHandle_M5 = INVALID_HANDLE; stochHandle_M5 = INVALID_HANDLE;
    }
    
    // Log M5
    if (g_enableLogsEffective) {
        if (!g_dataReady_M5) {
            Print("[INIT-HANDLES] M5: SKIP (TF non data-ready)");
        } else {
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
        PrintFormat("[INIT-HANDLES] M5: %d/%d handle creati %s", m5ok, 12, m5err == 0 ? "OK" : "ERRORI");
        }
    }
    
    // ---------------------------------------------------------------
    // H1: Timeframe intermedio
    // FIX: crea handle solo se TF data-ready
    // ---------------------------------------------------------------
    if (g_dataReady_H1) {
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
    } else {
        emaHandle_H1 = INVALID_HANDLE; macdHandle_H1 = INVALID_HANDLE; psarHandle_H1 = INVALID_HANDLE;
        smaFastHandle_H1 = INVALID_HANDLE; smaSlowHandle_H1 = INVALID_HANDLE; ichimokuHandle_H1 = INVALID_HANDLE;
        adxHandle_H1 = INVALID_HANDLE; bbHandle_H1 = INVALID_HANDLE; obvHandle_H1 = INVALID_HANDLE;
        atrHandle_H1 = INVALID_HANDLE; rsiHandle_H1 = INVALID_HANDLE; stochHandle_H1 = INVALID_HANDLE;
    }
    
    // Log H1
    if (g_enableLogsEffective) {
        if (!g_dataReady_H1) {
            Print("[INIT-HANDLES] H1: SKIP (TF non data-ready)");
        } else {
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
        PrintFormat("[INIT-HANDLES] H1: %d/%d handle creati %s", h1ok, 12, h1err == 0 ? "OK" : "ERRORI");
        }
    }
    
    // ---------------------------------------------------------------
    // H4: Timeframe swing
    // FIX: crea handle solo se TF data-ready
    // ---------------------------------------------------------------
    if (g_dataReady_H4) {
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
    } else {
        emaHandle_H4 = INVALID_HANDLE; macdHandle_H4 = INVALID_HANDLE; psarHandle_H4 = INVALID_HANDLE;
        smaFastHandle_H4 = INVALID_HANDLE; smaSlowHandle_H4 = INVALID_HANDLE; ichimokuHandle_H4 = INVALID_HANDLE;
        adxHandle_H4 = INVALID_HANDLE; bbHandle_H4 = INVALID_HANDLE; obvHandle_H4 = INVALID_HANDLE;
        atrHandle_H4 = INVALID_HANDLE; rsiHandle_H4 = INVALID_HANDLE; stochHandle_H4 = INVALID_HANDLE;
    }
    
    // Log H4
    if (g_enableLogsEffective) {
        if (!g_dataReady_H4) {
            Print("[INIT-HANDLES] H4: SKIP (TF non data-ready)");
        } else {
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
        PrintFormat("[INIT-HANDLES] H4: %d/%d handle creati %s", h4ok, 12, h4err == 0 ? "OK" : "ERRORI");
        }
    }
    
    // ---------------------------------------------------------------
    // D1: Timeframe trend lungo
    // FIX: crea handle solo se TF data-ready
    // ---------------------------------------------------------------
    if (g_dataReady_D1) {
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
    } else {
        emaHandle_D1 = INVALID_HANDLE; macdHandle_D1 = INVALID_HANDLE; psarHandle_D1 = INVALID_HANDLE;
        smaFastHandle_D1 = INVALID_HANDLE; smaSlowHandle_D1 = INVALID_HANDLE; ichimokuHandle_D1 = INVALID_HANDLE;
        adxHandle_D1 = INVALID_HANDLE; bbHandle_D1 = INVALID_HANDLE; obvHandle_D1 = INVALID_HANDLE;
        atrHandle_D1 = INVALID_HANDLE; rsiHandle_D1 = INVALID_HANDLE; stochHandle_D1 = INVALID_HANDLE;
    }
    
    // Log D1
    if (g_enableLogsEffective) {
        if (!g_dataReady_D1) {
            Print("[INIT-HANDLES] D1: SKIP (TF non data-ready)");
        } else {
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
        PrintFormat("[INIT-HANDLES] D1: %d/%d handle creati %s", d1ok, 12, d1err == 0 ? "OK" : "ERRORI");
        }
        PrintFormat("[INIT-HANDLES] TOTALE: %d/48 handle creati | Errori: %d %s",
            handleCount, handleErrors, handleErrors == 0 ? "OK" : "ERRORI");
    }
    
    // CORREZIONE: Valida solo i TF attivi; se un TF attivo ha handle mancanti, disattivalo invece di fallire
    if (g_dataReady_M5) {
        bool ok = (emaHandle_M5 != INVALID_HANDLE && macdHandle_M5 != INVALID_HANDLE &&
                   psarHandle_M5 != INVALID_HANDLE && adxHandle_M5 != INVALID_HANDLE);
        if (!ok) {
            Print("[INIT-HANDLES] M5 DISABILITATO: handle trend critici non creati");
            g_dataReady_M5 = false;
        }
    }
    if (g_dataReady_H1) {
        bool ok = (emaHandle_H1 != INVALID_HANDLE && macdHandle_H1 != INVALID_HANDLE &&
                   psarHandle_H1 != INVALID_HANDLE && adxHandle_H1 != INVALID_HANDLE);
        if (!ok) {
            Print("[INIT-HANDLES] H1 DISABILITATO: handle trend critici non creati");
            g_dataReady_H1 = false;
        }
    }
    if (g_dataReady_H4) {
        bool ok = (emaHandle_H4 != INVALID_HANDLE && macdHandle_H4 != INVALID_HANDLE &&
                   psarHandle_H4 != INVALID_HANDLE && adxHandle_H4 != INVALID_HANDLE);
        if (!ok) {
            Print("[INIT-HANDLES] H4 DISABILITATO: handle trend critici non creati");
            g_dataReady_H4 = false;
        }
    }
    if (g_dataReady_D1) {
        bool ok = (emaHandle_D1 != INVALID_HANDLE && macdHandle_D1 != INVALID_HANDLE &&
                   psarHandle_D1 != INVALID_HANDLE && adxHandle_D1 != INVALID_HANDLE);
        if (!ok) {
            Print("[INIT-HANDLES] D1 DISABILITATO: handle trend critici non creati");
            g_dataReady_D1 = false;
        }
    }

    int activeTf = (g_dataReady_M5 ? 1 : 0) + (g_dataReady_H1 ? 1 : 0) + (g_dataReady_H4 ? 1 : 0) + (g_dataReady_D1 ? 1 : 0);
    if (activeTf == 0) {
        Print("[INIT-HANDLES] ERRORE: nessun TF attivo dopo creazione handle - INIT_FAILED");
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Rilascio handles indicatori                                      |
//+------------------------------------------------------------------+
void ReleaseIndicators()
{
    if (g_enableLogsEffective) Print("[DEINIT-HANDLES] Inizio rilascio handle indicatori...");
    
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
        PrintFormat("[DEINIT-HANDLES] TOTALE: %d/48 handle rilasciati | Errori: %d %s",
            releasedCount, releaseErrors, releaseErrors == 0 ? "OK" : "ERRORI");
    }
}

//+------------------------------------------------------------------+
//| AGGIORNAMENTO VELOCE - Solo ultima barra (usa cache)             |
//| Invece di ricaricare tutto, aggiorna solo i valori piu' recenti  |
//+------------------------------------------------------------------+
bool UpdateLastBar(ENUM_TIMEFRAMES tf, TimeFrameData &data)
{
    // Se i dati non sono pronti, non possiamo aggiornare
    if (!data.isDataReady || ArraySize(data.rates) < 2) return false;
    
    int count = ArraySize(data.rates);
    int lastIdx = count - 1;
    
    // Carica solo barre CHIUSE (start=1) per coerenza con LoadTimeFrameData()
    MqlRates lastRates[];
    ArraySetAsSeries(lastRates, false);
    if (CopyRates(_Symbol, tf, 1, 2, lastRates) < 2) return false;
    
    // Aggiorna le ultime 2 barre chiuse nei rates (allineamento stabile)
    data.rates[lastIdx] = lastRates[1];
    data.rates[lastIdx-1] = lastRates[0];
    
    // Aggiorna indicatori principali per ultima barra (solo quelli necessari per il trade)
    // Seleziona handles appropriati per timeframe
    int emaH = INVALID_HANDLE, rsiH = INVALID_HANDLE, macdH = INVALID_HANDLE;
    int atrH = INVALID_HANDLE, adxH = INVALID_HANDLE, stochH = INVALID_HANDLE;
    int bbH = INVALID_HANDLE, psarH = INVALID_HANDLE;
    int smaFastH = INVALID_HANDLE, smaSlowH = INVALID_HANDLE, ichimokuH = INVALID_HANDLE;
    int obvH = INVALID_HANDLE;
    
    switch(tf) {
        case PERIOD_M5:  
            emaH = emaHandle_M5; rsiH = rsiHandle_M5; macdH = macdHandle_M5; 
            atrH = atrHandle_M5; adxH = adxHandle_M5; stochH = stochHandle_M5;
            bbH = bbHandle_M5; psarH = psarHandle_M5;
            smaFastH = smaFastHandle_M5; smaSlowH = smaSlowHandle_M5; ichimokuH = ichimokuHandle_M5;
            obvH = obvHandle_M5;
            break;
        case PERIOD_H1:  
            emaH = emaHandle_H1; rsiH = rsiHandle_H1; macdH = macdHandle_H1; 
            atrH = atrHandle_H1; adxH = adxHandle_H1; stochH = stochHandle_H1;
            bbH = bbHandle_H1; psarH = psarHandle_H1;
            smaFastH = smaFastHandle_H1; smaSlowH = smaSlowHandle_H1; ichimokuH = ichimokuHandle_H1;
            obvH = obvHandle_H1;
            break;
        case PERIOD_H4:  
            emaH = emaHandle_H4; rsiH = rsiHandle_H4; macdH = macdHandle_H4; 
            atrH = atrHandle_H4; adxH = adxHandle_H4; stochH = stochHandle_H4;
            bbH = bbHandle_H4; psarH = psarHandle_H4;
            smaFastH = smaFastHandle_H4; smaSlowH = smaSlowHandle_H4; ichimokuH = ichimokuHandle_H4;
            obvH = obvHandle_H4;
            break;
        case PERIOD_D1:  
            emaH = emaHandle_D1; rsiH = rsiHandle_D1; macdH = macdHandle_D1; 
            atrH = atrHandle_D1; adxH = adxHandle_D1; stochH = stochHandle_D1;
            bbH = bbHandle_D1; psarH = psarHandle_D1;
            smaFastH = smaFastHandle_D1; smaSlowH = smaSlowHandle_D1; ichimokuH = ichimokuHandle_D1;
            obvH = obvHandle_D1;
            break;
        default: return false;
    }

    // Se un handle critico manca, meglio forzare reload completo invece di lasciare dati stale
    if (emaH == INVALID_HANDLE || macdH == INVALID_HANDLE || psarH == INVALID_HANDLE ||
        smaFastH == INVALID_HANDLE || smaSlowH == INVALID_HANDLE || ichimokuH == INVALID_HANDLE ||
        adxH == INVALID_HANDLE || bbH == INVALID_HANDLE || atrH == INVALID_HANDLE ||
        rsiH == INVALID_HANDLE || stochH == INVALID_HANDLE || obvH == INVALID_HANDLE) {
        return false;
    }
    
    //  FIX CRITICO: Aggiorna TUTTI gli indicatori usati per il voto!
    double tempBuf[];
    ArrayResize(tempBuf, 2);
    ArraySetAsSeries(tempBuf, false);
    // Trend Primary
    if (CopyBuffer(emaH, 0, 1, 2, tempBuf) != 2) return false; else { data.ema[lastIdx] = tempBuf[1]; data.ema[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(macdH, 0, 1, 2, tempBuf) != 2) return false; else { data.macd[lastIdx] = tempBuf[1]; data.macd[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(macdH, 1, 1, 2, tempBuf) != 2) return false; else { data.macd_signal[lastIdx] = tempBuf[1]; data.macd_signal[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(psarH, 0, 1, 2, tempBuf) != 2) return false; else { data.psar[lastIdx] = tempBuf[1]; data.psar[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(smaFastH, 0, 1, 2, tempBuf) != 2) return false; else { data.sma_fast[lastIdx] = tempBuf[1]; data.sma_fast[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(smaSlowH, 0, 1, 2, tempBuf) != 2) return false; else { data.sma_slow[lastIdx] = tempBuf[1]; data.sma_slow[lastIdx-1] = tempBuf[0]; }
    // Ichimoku (4 linee)
    if (CopyBuffer(ichimokuH, 0, 1, 2, tempBuf) != 2) return false; else { data.ichimoku_tenkan[lastIdx] = tempBuf[1]; data.ichimoku_tenkan[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(ichimokuH, 1, 1, 2, tempBuf) != 2) return false; else { data.ichimoku_kijun[lastIdx] = tempBuf[1]; data.ichimoku_kijun[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(ichimokuH, 2, 1, 2, tempBuf) != 2) return false; else { data.ichimoku_senkou_a[lastIdx] = tempBuf[1]; data.ichimoku_senkou_a[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(ichimokuH, 3, 1, 2, tempBuf) != 2) return false; else { data.ichimoku_senkou_b[lastIdx] = tempBuf[1]; data.ichimoku_senkou_b[lastIdx-1] = tempBuf[0]; }
    // Trend Support
    if (CopyBuffer(bbH, 1, 1, 2, tempBuf) != 2) return false; else { data.bb_upper[lastIdx] = tempBuf[1]; data.bb_upper[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(bbH, 0, 1, 2, tempBuf) != 2) return false; else { data.bb_middle[lastIdx] = tempBuf[1]; data.bb_middle[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(bbH, 2, 1, 2, tempBuf) != 2) return false; else { data.bb_lower[lastIdx] = tempBuf[1]; data.bb_lower[lastIdx-1] = tempBuf[0]; }
    // Filters & Mean-Reversion
    if (CopyBuffer(atrH, 0, 1, 2, tempBuf) != 2) return false; else { data.atr[lastIdx] = tempBuf[1]; data.atr[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(adxH, 0, 1, 2, tempBuf) != 2) return false; else { data.adx[lastIdx] = tempBuf[1]; data.adx[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(rsiH, 0, 1, 2, tempBuf) != 2) return false; else { data.rsi[lastIdx] = tempBuf[1]; data.rsi[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(stochH, 0, 1, 2, tempBuf) != 2) return false; else { data.stoch_main[lastIdx] = tempBuf[1]; data.stoch_main[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(stochH, 1, 1, 2, tempBuf) != 2) return false; else { data.stoch_signal[lastIdx] = tempBuf[1]; data.stoch_signal[lastIdx-1] = tempBuf[0]; }
    if (CopyBuffer(obvH, 0, 1, 2, tempBuf) != 2) return false; else { data.obv[lastIdx] = tempBuf[1]; data.obv[lastIdx-1] = tempBuf[0]; }
    
    //  FIX: Aggiorna anche Heikin Ashi (calcolato da rates)
    // HA Close = (O+H+L+C)/4
    data.ha_close[lastIdx] = (data.rates[lastIdx].open + data.rates[lastIdx].high + 
                              data.rates[lastIdx].low + data.rates[lastIdx].close) / 4.0;
    // HA Open = (prev HA Open + prev HA Close) / 2
    if (lastIdx > 0) {
        data.ha_open[lastIdx] = (data.ha_open[lastIdx-1] + data.ha_close[lastIdx-1]) / 2.0;
    } else {
        data.ha_open[lastIdx] = (data.rates[lastIdx].open + data.rates[lastIdx].close) / 2.0;
    }
    
    //  FIX CRITICO: Ricalcola valori organici (ATR_avg, ADX_threshold, ecc.)
    // Questi DEVONO essere aggiornati ad ogni barra, altrimenti diventano stale!
    // Usa minBarsRequired dal data.organic (gi calcolato in LoadTimeFrameData)
    int minBarsRequired = data.organic.min_bars_required;
    if (minBarsRequired == 0) {
        // Fallback se non impostato: usa periodo naturale * 2
        minBarsRequired = MathMax(10, data.organic.naturalPeriod * 2);
    }
    CalculateOrganicValues(data, count, minBarsRequired);
    
    return true;
}

//+------------------------------------------------------------------+
//|  Caricamento dati timeframe con calcolo valori organici        |
//|  FIX: Usa start=1 per caricare dati STORICI (passato)          |
//+------------------------------------------------------------------+
bool LoadTimeFrameData(ENUM_TIMEFRAMES tf, TimeFrameData &data, int bars)
{
    static int warnInsufficientData[32];  // Piccolo contatore per evitare spam di log

    // FIX: Usa start=1 per garantire dati dal passato, non dalla barra corrente incompleta
    ArraySetAsSeries(data.rates, false);
    int copiedBars = CopyRates(_Symbol, tf, 1, bars, data.rates);
    if (copiedBars <= 0) {
        PrintFormat("[ERROR] Impossibile caricare rates per TF %s", EnumToString(tf));
        return false;
    }
    
    // FIX: Non piu warning "dati parziali" - ora usiamo quello che c'e
    // Se servono N barre e ne abbiamo M < N, usiamo M (il sistema si adatta)
    
    // FIX: Verifica che i dati non siano corrotti (prezzi validi)
    // Numero barre da verificare = periodo  decay(H) (data-driven)
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    int barsToCheck = MathMax(4, (int)MathRound(basePeriod * GetOrganicDecayPow(GetDefaultHurst(), 2.0)));

    // Se abbiamo meno barre del minimo, rinuncia (policy: SOLO barre chiuse, niente start=0)
    if (copiedBars < barsToCheck) {
        int idx = MathMin(31, (int)tf % 32);
        if (warnInsufficientData[idx] < 3) {
            PrintFormat("[WARN] TF %s: Dati insufficienti (%d/%d barre chiuse). Ritento al prossimo tick.",
                EnumToString(tf), copiedBars, barsToCheck);
            warnInsufficientData[idx]++;
        }
        return false;
    }
    int invalidBars = 0;
    for (int i = 0; i < MathMin(copiedBars, barsToCheck); i++) {
        if (data.rates[i].close <= 0 || data.rates[i].open <= 0 ||
            data.rates[i].high <= 0 || data.rates[i].low <= 0 ||
            data.rates[i].high < data.rates[i].low) {
            invalidBars++;
        }
    }
    // Soglia = met delle barre verificate massime
    int maxInvalidBars = barsToCheck / 2;
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

    // Enforce ordering coerente (oldest->newest) per tutto il TF
    SetTimeFrameArraysNonSeries(data);
    
    //  Inizializza valori organici (saranno calcolati dai DATI dopo il caricamento)
    data.atr_avg = 0;
    data.adx_avg = 0;
    data.adx_stddev = 0;
    data.adx_threshold = 0;  // Verra' calcolato da CalculateOrganicValues
    data.isDataReady = false;
    
    //  PURO: Inizializza tutto a 0 - verranno calcolati dai DATI
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
    
    //  FIX: Copia buffers indicatori da start=1 per allineamento con CopyRates(start=1)
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
    //  CALCOLO VALORI ORGANICI (ATR medio, ADX threshold dinamico)
    // Questi valori si auto-adattano ai dati storici disponibili
    // ---------------------------------------------------------------
    CalculateOrganicValues(data, count, minBarsRequired);
    
    return true;
}

//+------------------------------------------------------------------+
//| Calcolo valori organici per ATR e ADX - PURO                     |
//| FORMULA ATR: atr_avg = media(ATR ultime N barre)                 |
//| FORMULA ADX: adx_threshold = media(ADX) + decay(H) * stddev(ADX) |
//| Se dati insufficienti -> isDataReady = false (no fallback!)      |
//+------------------------------------------------------------------+
void CalculateOrganicValues(TimeFrameData &data, int count, int minBarsRequired)
{
    // Verifica se abbiamo abbastanza dati
    if (count < minBarsRequired) {
        //  Log pi diagnostico per capire il blocco
        static int insufficientDataCount = 0;
        insufficientDataCount++;
        if (insufficientDataCount <= 3 || insufficientDataCount % 20 == 0) {
            PrintFormat("[ORGANIC WARN #%d] Barre insufficienti: %d < %d richieste", 
                insufficientDataCount, count, minBarsRequired);
        }
        //  NON impostare isDataReady=false se era gi true!
        // Mantieni i dati vecchi invece di bloccare
        if (!data.isDataReady) {
            data.isDataReady = false;  // Solo se non era gi pronto
            return;
        }
        // Se era gi pronto, continua con i dati esistenti (non aggiornati)
        return;
    }
    
    int lastIdx = count - 1;
    
    // ---------------------------------------------------------------
    // LOOKBACK derivato dal naturalPeriod * scale(H)
    // Solo UN moltiplicatore basato su H, non potenze arbitrarie!
    // Il naturalPeriod gia deriva dai DATI (autocorrelazione)
    // ---------------------------------------------------------------
    int organicLookback = (int)MathRound(data.organic.naturalPeriod * GetOrganicScale(g_hurstGlobal));
    int lookback = MathMin(organicLookback, count - 1);
    lookback = MathMax(lookback, 3);  // Minimo 3 barre
    
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
        //  FIX: Se ATR invalido, usa fallback invece di bloccare!
        data.atr_avg = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 100;  // ~100 pips come fallback
        if (g_enableLogsEffective) {
            PrintFormat("[ORGANIC] ATR invalido - usando fallback: %.5f", data.atr_avg);
        }
    } else {
        data.atr_avg = atr_sum / atr_count;
    }
    
    // ---------------------------------------------------------------
    // ADX ORGANICO: Media + decay(H) * deviazione standard
    // Formula: threshold = avg(ADX) + decay(H) * sqrt(sum((ADX-avg)^2)/N)
    // Questo identifica quando ADX e "significativamente sopra" la norma
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
        //  FIX DATA-DRIVEN: Calcola fallback da min/max ADX disponibili o range teorico
        int availableSize = ArraySize(data.adx);
        if (availableSize >= 2) {
            double adx_min = data.adx[0], adx_max = data.adx[0];
            for (int j = 1; j < availableSize; j++) {
                if (data.adx[j] < adx_min) adx_min = data.adx[j];
                if (data.adx[j] > adx_max) adx_max = data.adx[j];
            }
            data.adx_avg = (adx_min + adx_max) / 2.0;  // Centro range osservato
        } else {
            // ESTREMO: ADX range teorico [0, 100] derivato matematicamente
            // Centro = (min + max) / 2 dove min=0, max=100
            data.adx_avg = (0.0 + 100.0) / 2.0;  // Centro range teorico (formula, non hardcoded)
        }
        if (g_enableLogsEffective) {
            PrintFormat("[ORGANIC] ADX dati insufficienti - fallback data-driven: %.1f", data.adx_avg);
        }
    } else {
        data.adx_avg = adx_sum / adx_count;
    }
    
    // Calcola deviazione standard
    double variance_sum = 0;
    for (int i = lastIdx - lookback; i <= lastIdx; i++) {
        if (i >= 0 && i < ArraySize(data.adx)) {
            double diff = data.adx[i] - data.adx_avg;
            variance_sum += diff * diff;
        }
    }
    data.adx_stddev = MathSqrt(variance_sum / adx_count);
    
    //  FIX: Se ADX stddev=0 (mercato flat), NON bloccare - usa fallback!
    if (data.adx_stddev <= 0) {
        // Mercato molto stabile - usa 10% della media come pseudo-stddev
        data.adx_stddev = data.adx_avg * 0.1;
        if (data.adx_stddev <= 0) data.adx_stddev = 1.0;  // Fallback assoluto
        if (g_enableLogsEffective) {
            PrintFormat("[ORGANIC] ADX stddev=0 (flat) - usando fallback: %.2f", data.adx_stddev);
        }
    }
    
    // ---------------------------------------------------------------
    // CALCOLA SOGLIE EMPIRICHE per tutti gli oscillatori
    // Centri e scale derivano dai DATI storici, non da costanti teoriche!
    // Se fallisce, invalida il TF (no fallback!)
    // ---------------------------------------------------------------
    bool empiricalOK = CalculateEmpiricalThresholds(data, lookback);
    
    //  FIX DATA-DRIVEN: Se soglie empiriche falliscono, calcola da min/max disponibili
    if (!empiricalOK) {
        // Calcola fallback da dati REALI (anche se pochi)
        int availableSize = ArraySize(data.rsi);
        if (availableSize >= 4) {
            // RSI: centro = (min+max)/2, scale = range/4
            double rsi_min = data.rsi[0], rsi_max = data.rsi[0];
            for (int i = 1; i < availableSize; i++) {
                if (data.rsi[i] < rsi_min) rsi_min = data.rsi[i];
                if (data.rsi[i] > rsi_max) rsi_max = data.rsi[i];
            }
            data.rsi_center = (rsi_min + rsi_max) / 2.0;
            data.rsi_scale = (rsi_max - rsi_min) / 4.0;
            
            // Stoch: stesso metodo
            double stoch_min = data.stoch_main[0], stoch_max = data.stoch_main[0];
            for (int i = 1; i < MathMin(availableSize, ArraySize(data.stoch_main)); i++) {
                if (data.stoch_main[i] < stoch_min) stoch_min = data.stoch_main[i];
                if (data.stoch_main[i] > stoch_max) stoch_max = data.stoch_main[i];
            }
            data.stoch_center = (stoch_min + stoch_max) / 2.0;
            data.stoch_scale = (stoch_max - stoch_min) / 4.0;
            
            // ADX: percentili approssimati da min/max
            double adx_min = data.adx[0], adx_max = data.adx[0];
            for (int i = 1; i < MathMin(availableSize, ArraySize(data.adx)); i++) {
                if (data.adx[i] < adx_min) adx_min = data.adx[i];
                if (data.adx[i] > adx_max) adx_max = data.adx[i];
            }
            // p25  min + 25% range, p75  min + 75% range (adattivi a Hurst)
            double adx_range = adx_max - adx_min;
            double hurstDev = (GetDefaultHurst() - 0.5) * 20.0;
            double p_low_pct = MathMax(0.1, MathMin(0.4, 0.25 + hurstDev / 100.0));
            double p_high_pct = MathMax(0.6, MathMin(0.9, 0.75 + hurstDev / 100.0));
            data.adx_p25 = adx_min + adx_range * p_low_pct;   // ~25% per H=0.5
            data.adx_p75 = adx_min + adx_range * p_high_pct;  // ~75% per H=0.5
            
            if (g_enableLogsEffective) {
                PrintFormat("[ORGANIC] Fallback data-driven: RSI[%.1f%.1f] Stoch[%.1f%.1f] ADX[%.1f-%.1f]",
                    data.rsi_center, data.rsi_scale, data.stoch_center, data.stoch_scale, data.adx_p25, data.adx_p75);
            }
        } else {
            // ESTREMO fallback: solo se <4 dati (impossibile calcolare niente)
            data.rsi_center = 0;
            data.rsi_scale = 0;
            data.stoch_center = 0;
            data.stoch_scale = 0;
            data.adx_p25 = 0;
            data.adx_p75 = 0;
            if (g_enableLogsEffective) {
                Print("[ORGANIC] Dati insufficienti per fallback - TF invalidato");
            }
        }
    }
    
    // Soglia ADX organica = media + decay(H) * stddev ~ avg + 0.6*stddev
    // decay(H) = 2^(-H) definisce la proporzione tra media e variazione
    data.adx_threshold = data.adx_avg + GetOrganicDecay(g_hurstGlobal) * data.adx_stddev;
    
    // Limita la soglia usando PERCENTILI empirici invece di potenze arbitrarie
    // I limiti ora derivano dalla distribuzione REALE dei dati ADX
    data.adx_threshold = MathMax(data.adx_p25, MathMin(data.adx_p75, data.adx_threshold));
    
    // Tutti i calcoli completati con successo
    data.isDataReady = true;
    
    if (g_enableLogsEffective) {
        PrintFormat("[ORGANIC] TF ready: ATR_avg=%.5f ADX_threshold=%.1f lookback=%d",
            data.atr_avg, data.adx_threshold, lookback);
    }
}

//+------------------------------------------------------------------+
//| Calcolo indicatori personalizzati OTTIMIZZATO O(n)               |
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
//| Calcolo segnali per timeframe con pesi specifici                 |
//| LOGICA NORMALIZZATA TREND-FOLLOWING:                            |
//| Tutti gli indicatori: >0 = BUY, <0 = SELL                       |
//| I pesi moltiplicano i valori normalizzati                        |
//| ADX: trend-following (ADX alto + DI per direzione)              |
//| ATR: contrarian (ATR > media = possibile inversione)            |
//|                                                                  |
//| SOGLIE ORGANICHE:                                                |
//|   ADX threshold = data.adx_threshold (calcolato dinamicamente)   |
//|   ATR threshold = data.atr_avg (media dinamica, no moltiplicatore)|
//|                                                                  |
//| PESI ORGANICI (sostituiscono 72 input hardcodati):               |
//|   Ogni indicatore usa enable bool + peso TF organico             |
//|   peso_TF = data.organic.weight (auto-calcolato)                 |
//+------------------------------------------------------------------+
double CalculateSignalScore(TimeFrameData &data, string timeframe)
// NOTA: Usa direttamente enableXXX (bool globali) e data.organic.weight (peso organico TF)
{
    int lastIdx = ArraySize(data.rates) - 1;
    if (lastIdx < 1) return 0;
    
    // Verifica se i dati sono pronti per il calcolo organico
    if (!data.isDataReady) {
        return 0;  // Non abbiamo abbastanza dati, non generare segnali
    }
    
    double price = data.rates[lastIdx].close;
    // USA g_pointValue CACHATO (inizializzato in OnInit)
    double point_value = g_pointValue;
    
    // SCALA ORGANICA: usa ATR medio * scale(H) come unita di volatilita
    // scale(H) = 2^H ~ 1.4-1.6 per H tipico 0.5-0.7
    // Distanza = scale(H) * ATR per raggiungere normalizzazione +/-1
    // Minimo organico = naturalPeriod * scale(H) pips (derivato dai DATI)
    double scale = GetOrganicScale(g_hurstGlobal);
    double min_organic_scale = point_value * data.organic.naturalPeriod * scale;
    
    // FIX: Protezione divisione per zero con fallback multipli
    double atr_scale = data.atr_avg * scale;  // Scala primaria
    
    // Fallback 1: usa min_organic_scale se ATR troppo basso
    if (atr_scale < min_organic_scale || atr_scale <= 0) {
        atr_scale = min_organic_scale;
    }
    
    // Fallback 2: se ancora zero, usa point_value * scale
    if (atr_scale <= 0) {
        atr_scale = point_value * scale;
    }
    
    // Fallback 3: minimo assoluto = 0.00001 (5 decimali forex)
    if (atr_scale <= 0) {
        atr_scale = 0.00001;
    }
    
    // VALIDATO: atr_scale sempre > 0 dopo tutti i fallback
    
    // 
    // CALCOLO VALORI NORMALIZZATI (>0 = BUY, <0 = SELL)
    // 
    
    double totalScore = 0;
    
    // Peso organico del TF (calcolato da Hurst: peso = H_TF / Sum(H_tutti_TF))
    double w = data.organic.weight;
    
    //  PESI RELATIVI PER CATEGORIA (Hurst-derivati)
    // TREND PRIMARIO: peso base = 1.0 (riferimento)
    // TREND SUPPORT:  peso = decay(H) (conferma, non guida)
    // TREND FILTER:   peso = 1.0 ma condizionale (solo se ADX > soglia)
    double w_primary = w * 1.0;       // EMA, MACD, PSAR, SMA, Ichimoku
    double w_support = w * GetOrganicDecay(g_hurstGlobal);   // BB, Heikin
    double w_filter = w * 1.0;        // ADX (condizionale)
    
    // 
    //  TREND PRIMARIO (peso pieno)
    // 
    
    // EMA: prezzo - EMA (positivo = sopra EMA = BUY)
    //  Scala ORGANICA: distanza normalizzata con ATR (non pips fissi)
    if (enableEMA && ArraySize(data.ema) > lastIdx) {
        double ema_norm = (price - data.ema[lastIdx]) / atr_scale;
        ema_norm = MathMax(-1.0, MathMin(1.0, ema_norm));
        totalScore += ema_norm * w_primary;
    }
    
    // MACD: differenza MACD - Signal (gi trend-following)
    //  Scala ORGANICA: differenza normalizzata con ATR
    if (enableMACD && ArraySize(data.macd) > lastIdx && ArraySize(data.macd_signal) > lastIdx) {
        double macd_diff = data.macd[lastIdx] - data.macd_signal[lastIdx];
        double macd_norm = MathMax(-1.0, MathMin(1.0, macd_diff / atr_scale));
        totalScore += macd_norm * w_primary;
    }
    
    // 
    //  PSAR (Parabolic SAR): Trend-following puro - PRIMARIO
    // Prezzo > PSAR = BUY (+1), Prezzo < PSAR = SELL (-1)
    // Intensit proporzionale alla distanza normalizzata
    // 
    if (enablePSAR && ArraySize(data.psar) > lastIdx) {
        double psar_dist = (price - data.psar[lastIdx]) / atr_scale;
        double psar_norm = MathMax(-1.0, MathMin(1.0, psar_dist));
        totalScore += psar_norm * w_primary;
    }
    
    // 
    //  SMA CROSS: SMA Fast vs SMA Slow (Golden/Death Cross) - PRIMARIO
    // Fast > Slow = BUY, Fast < Slow = SELL
    // Intensit proporzionale alla distanza normalizzata
    // 
    if (enableSMA && ArraySize(data.sma_fast) > lastIdx && ArraySize(data.sma_slow) > lastIdx) {
        double sma_diff = (data.sma_fast[lastIdx] - data.sma_slow[lastIdx]) / atr_scale;
        double sma_norm = MathMax(-1.0, MathMin(1.0, sma_diff));
        totalScore += sma_norm * w_primary;
    }
    
    // 
    //  ICHIMOKU: Sistema multi-fattore trend-following - PRIMARIO
    // Segnali: Tenkan/Kijun cross + Price vs Cloud
    // BUY: Price > Cloud + Tenkan > Kijun
    // SELL: Price < Cloud + Tenkan < Kijun
    // 
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
            double decay = GetOrganicDecay(g_hurstGlobal);
            double cloud_width = cloud_top - cloud_bottom;
            double denominator = (cloud_width / 2.0) + (atr_scale * decay);
            // Protezione divisione per zero
            if (denominator < atr_scale * 0.01) denominator = atr_scale * 0.01;
            cloud_signal = (price - cloud_mid) / denominator;
            //  FIX: Clamp data-driven invece di 0.5 arbitrario
            cloud_signal = MathMax(-decay, MathMin(decay, cloud_signal));  // Dentro cloud = max decay
        }
        
        //  Combina i segnali con pesi: scale(H) per TK cross, 1 per cloud
        double scale = GetOrganicScale(g_hurstGlobal);
        double ichi_score = (tk_signal * scale + cloud_signal) / (scale + 1.0);
        totalScore += ichi_score * w_primary;  //  TREND PRIMARY
    }
    
    // Bollinger Bands: posizione relativa nel range
    //  FIX: Protezione divisione per zero con minimo data-driven
    if (enableBB && ArraySize(data.bb_upper) > lastIdx && ArraySize(data.bb_lower) > lastIdx && ArraySize(data.bb_middle) > lastIdx) {
        double bb_range = data.bb_upper[lastIdx] - data.bb_lower[lastIdx];
        //  FIX: Minimo BB range = ATR * decay^2 (evita divisione per valori troppo piccoli)
        double min_bb_range = atr_scale * GetOrganicDecayPow(g_hurstGlobal, 2);
        if (min_bb_range <= 0) min_bb_range = point_value * 2.0;  // Fallback assoluto
        
        double bb_norm = 0;
        if (bb_range > min_bb_range) {
            bb_norm = (price - data.bb_middle[lastIdx]) / (bb_range / 2.0);
            bb_norm = MathMax(-1.0, MathMin(1.0, bb_norm));
        }
        // Se bb_range <= min_bb_range, bande troppo strette, segnale neutro (0)
        totalScore += bb_norm * w_support;  //  TREND SUPPORT
    }
    
    // ATR: indicatore di volatilit (non direzionale) - escluso dal voto direzionale
    // ADX: forza del trend (non direzionale) - escluso dal voto direzionale
    // Entrambi possono essere usati esternamente come filtri ma non contribuiscono allo score
    
    // ---------------------------------------------------------------
    //  INDICATORI ADDIZIONALI
    // ---------------------------------------------------------------
    
    //  Heikin Ashi: close - open
    //  Scala ORGANICA: usa decay(H) dell'ATR (corpo HA = proporzione Hurst del range)
    if (enableHeikin && ArraySize(data.ha_close) > lastIdx && ArraySize(data.ha_open) > lastIdx) {
        double ha_diff = data.ha_close[lastIdx] - data.ha_open[lastIdx];
        double ha_norm = MathMax(-1.0, MathMin(1.0, ha_diff / (atr_scale * GetOrganicDecay(g_hurstGlobal))));
        totalScore += ha_norm * w_support;  //  TREND SUPPORT
    }
    
    //  v1.1: OBV  MEAN-REVERSION - vota nella sezione combinata (non qui)
    // L'OBV vota inversione nella sezione CalculateMultiTimeframeScore
    // dove  combinato con RSI e Stochastic per votare direzione inversione
    
    // 
    //  ADX: TREND-FOLLOWING 100% DATA-DRIVEN (basato su 2^H)
    // Soglia: avg + decay(H)  stddev
    // Max forte: avg + scale^2  stddev
    // DI norm: basato su stddev  scale
    // ---------------------------------------------------------------
    if (enableADX && ArraySize(data.adx) > lastIdx && ArraySize(data.di_plus) > lastIdx && ArraySize(data.di_minus) > lastIdx) {
        double adx_val = data.adx[lastIdx];
        double di_plus = data.di_plus[lastIdx];
        double di_minus = data.di_minus[lastIdx];
        
        //  Valori data-driven derivati da 2^H e statistiche del mercato
        double scale = GetOrganicScale(g_hurstGlobal);
        double scaleSq = GetOrganicScalePow(g_hurstGlobal, 2);
        double adx_threshold_organic = data.adx_threshold;                         // avg + decay*stddev
        double adx_max_organic = data.adx_avg + scaleSq * data.adx_stddev;         // scale^2 sigma = molto forte
        double di_scale_organic = MathMax(scaleSq, data.adx_stddev * scale);       // min scale^2
        
        // Solo se ADX supera la soglia data-driven (trend significativo per questo mercato)
        if (adx_val > adx_threshold_organic && adx_max_organic > adx_threshold_organic) {
            //  Forza normalizzata: (ADX - soglia) / (max - soglia)
            double adx_strength = MathMin(1.0, (adx_val - adx_threshold_organic) / (adx_max_organic - adx_threshold_organic));
            
            //  Direzione basata su +DI vs -DI, normalizzata con scale
            double di_diff = di_plus - di_minus;
            double di_norm = MathMax(-1.0, MathMin(1.0, di_diff / di_scale_organic));
            
            // Score = direzione * forza del trend * peso
            totalScore += di_norm * adx_strength * w_filter;  //  TREND FILTER (condizionale)
            
            //  Log ADX (se abilitato)
            if (g_enableLogsEffective) {
                PrintFormat("[%s] ADX DATA-DRIVEN: val=%.1f > soglia=%.1f (max=%.1f) -> DI+:%.1f DI-:%.1f scale=%.1f",
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
    // Aggiorna trailing stop per proteggere profitti
    UpdateTrailingStops();
    
    //  Exit anticipato su segnali reversal contrari (taglia perdite grosse)
    CheckEarlyExitOnReversal();
    
    // Controlla eventuale stop loss temporale
    CheckAndCloseOnTimeStop();
    
    // ---------------------------------------------------------------
    // WARMUP: Verifica se il preload storico  andato a buon fine
    // Il buffer Hurst viene pre-caricato in OnInit() da PreloadHurstBufferFromHistory()
    // Qui controlliamo solo che i flag siano pronti, non aspettiamo tempo reale
    //  FIX: Dopo 50 barre, forza warmup completato per evitare blocco
    // ---------------------------------------------------------------
    if (!g_warmupComplete) {
        //  FIX: Contatore barre warmup per evitare blocco permanente
        static int warmupBarCount = 0;
        static int warmupTickCount = 0;  // Conta anche i tick per timeout assoluto
        warmupBarCount++;
        warmupTickCount++;
        // Protezione overflow: reset se troppo alti
        if (warmupBarCount > 1000000) warmupBarCount = 51;
        if (warmupTickCount > 1000000) warmupTickCount = 501;
        
        // FIX: Se Hurst filter  disabilitato, skip check buffer Hurst
        bool hurstBufferReady = true;
        bool tradeScoreBufferReady = true;
        bool hurstReadyCheck = true;
        
        // Soglia minima = decay^2 del buffer massimo (~25% per H=0.5)
        double minBufferFraction = GetOrganicDecayPow(g_hurstGlobal > 0 ? g_hurstGlobal : GetDefaultHurst(), 2.0);
        int hurstMinRequired = (int)MathCeil(HURST_HISTORY_MAX * minBufferFraction);
        int scoreMinRequired = (int)MathCeil(TRADE_SCORE_HISTORY_MAX * minBufferFraction);
        
        if (EnableHurstFilter) {
            hurstBufferReady = (g_hurstHistorySize >= hurstMinRequired);
            tradeScoreBufferReady = (g_tradeScoreHistorySize >= scoreMinRequired);
            hurstReadyCheck = g_hurstReady;
        }
        
        //  NO WARMUP FORZATO - aspetta dati completi
        // Trading permesso solo quando tutti i buffer sono pronti
        if (hurstBufferReady && tradeScoreBufferReady && hurstReadyCheck) {
            g_warmupComplete = true;
            if (EnableHurstFilter) {
                Print("[WARMUP] Buffer pre-caricati dallo storico - EA pronto per il trading");
            } else {
                Print("[WARMUP] Hurst filter DISABILITATO - EA pronto per il trading (no buffer richiesti)");
            }
        } else {
            // Preload fallito - tenta ricalcolo incrementale
            // Log anti-spam: stampa solo su avanzamenti a step o cambio stato.
            if (EnableLogs) {
                int hurstReq = MathMax(1, hurstMinRequired);
                int scoreReq = MathMax(1, scoreMinRequired);
                int hurstNow = MathMin(g_hurstHistorySize, hurstReq);
                int scoreNow = MathMin(g_tradeScoreHistorySize, scoreReq);
                int hurstPct = (int)MathFloor(100.0 * (double)hurstNow / (double)hurstReq);
                int scorePct = (int)MathFloor(100.0 * (double)scoreNow / (double)scoreReq);

                static int  lastHurstPct = -1;
                static int  lastScorePct = -1;
                static bool lastHurstBufReady = false;
                static bool lastScoreBufReady = false;
                static bool lastHurstReadyFlag = false;

                bool pctStepH = (hurstPct != lastHurstPct) && (hurstPct % 5 == 0 || hurstPct >= 100);
                bool pctStepS = (scorePct != lastScorePct) && (scorePct % 5 == 0 || scorePct >= 100);
                bool stateChanged = (hurstBufferReady != lastHurstBufReady) || (tradeScoreBufferReady != lastScoreBufReady) || (g_hurstReady != lastHurstReadyFlag);

                if (lastHurstPct < 0 || pctStepH || pctStepS || stateChanged) {
                    PrintFormat("[WARMUP] Attesa dati: HurstBuf=%d/%d (%d%%) TradeScoreBuf=%d/%d (%d%%) HurstReady=%s",
                        g_hurstHistorySize, hurstReq, hurstPct,
                        g_tradeScoreHistorySize, scoreReq, scorePct,
                        g_hurstReady ? "SI" : "NO");
                    lastHurstPct = hurstPct;
                    lastScorePct = scorePct;
                    lastHurstBufReady = hurstBufferReady;
                    lastScoreBufReady = tradeScoreBufferReady;
                    lastHurstReadyFlag = g_hurstReady;
                }
            }
            
            // Aggiorna sistema per raccogliere dati incrementalmente
            datetime currentBarTime_warmup = iTime(_Symbol, PERIOD_CURRENT, 0);
            static datetime lastBarTime_warmup = 0;
            if (currentBarTime_warmup != lastBarTime_warmup && currentBarTime_warmup > 0) {
                lastBarTime_warmup = currentBarTime_warmup;
                RecalculateOrganicSystem();
            }
            
            //  FIX: Log periodico per diagnosticare se EA si  bloccato
            if (warmupTickCount % 100 == 0) {
                PrintFormat("[WARMUP ALIVE #%d] EA attivo, warmup in corso... Tick=%d Barre=%d",
                    warmupTickCount / 100, warmupTickCount, warmupBarCount);
            }
            
            return;  // Non proseguire con trading finche buffer non pronti
        }
    }
    
    // Controlla nuovo bar del TF corrente (quello del grafico)
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    
    //  FIX: Diagnostica se iTime fallisce (ritorna 0)
    if (currentBarTime == 0) {
        static int iTimeFailCount = 0;
        iTimeFailCount++;
        if (iTimeFailCount <= 5 || iTimeFailCount % 50 == 0) {
            PrintFormat("[ERROR CRITICO #%d] iTime() ritorna 0 - problema connessione/dati!", iTimeFailCount);
        }
        // Prova a continuare comunque dopo 10 fallimenti
        if (iTimeFailCount > 10) {
            currentBarTime = TimeCurrent();  // Usa time corrente come fallback
        } else {
            return;
        }
    }
    
    if (currentBarTime == lastBarTime) return;
    lastBarTime = currentBarTime;
    
    //  HEARTBEAT: Log periodico per confermare che EA  vivo (anche in backtest)
    static int totalBarsProcessed = 0;
    totalBarsProcessed++;
    // Protezione overflow: reset ogni milione di barre
    if (totalBarsProcessed > 1000000) totalBarsProcessed = 1;
    if (totalBarsProcessed == 1 || totalBarsProcessed % 500 == 0) {
        PrintFormat("[EA HEARTBEAT] Barra #%d processata - %s - EA ATTIVO", 
            totalBarsProcessed, TimeToString(currentBarTime, TIME_DATE|TIME_MINUTES));
    }
    
    // ---------------------------------------------------------------
    // OTTIMIZZAZIONE: Ricalcolo ogni N barre (non ogni barra)
    // ---------------------------------------------------------------
    g_barsSinceLastRecalc++;
    
    bool shouldRecalc = false;
    if (RecalcEveryBars <= 0) {
        // Comportamento originale: ricalcola sempre
        shouldRecalc = true;
    } else {
        // OTTIMIZZATO: ricalcola solo ogni N barre
        if (g_barsSinceLastRecalc >= RecalcEveryBars) {
            shouldRecalc = true;
            g_barsSinceLastRecalc = 0;
        }
    }
    
    if (g_enableLogsEffective) {
        Print("");
        Print("+---------------------------------------------------------------------------+");
        PrintFormat("NUOVA BARRA %s - %s", 
            EnumToString(Period()), TimeToString(currentBarTime, TIME_DATE|TIME_MINUTES));
        if (shouldRecalc) {
            Print("Avvio ricalcolo completo sistema organico...");
        } else {
            PrintFormat("Skip ricalcolo (%d/%d barre)",
                g_barsSinceLastRecalc, RecalcEveryBars);
        }
        Print("+---------------------------------------------------------------------------+");
    }
    
    // ---------------------------------------------------------------
    // RICALCOLO SISTEMA ORGANICO (condizionale per performance)
    // ---------------------------------------------------------------
    if (shouldRecalc) {
        RecalculateOrganicSystem();
    }
    
    // Carica dati multi-timeframe per analisi
    // Sistema robusto: continua con i TF disponibili
    // OTTIMIZZATO: Ricarica solo ogni N barre
    if (g_enableLogsEffective) Print("[DATA] Caricamento dati multi-timeframe in corso...");
    
    // CHECK CACHE DATI TF - Ricarica solo se necessario
    // Intervallo reload dati = RecalcEveryBars / periodo  decay(H) (data-driven)
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : BOOTSTRAP_MIN_BARS;
    int tfDataReloadDivisor = MathMax(2, (int)MathRound(basePeriod * GetOrganicDecayPow(GetDefaultHurst(), 2.0)));
    int tfDataReloadInterval = MathMax(1, RecalcEveryBars / tfDataReloadDivisor);  // Reload dinamico
    bool shouldReloadTFData = false;
    
    if (!g_tfDataCacheValid || g_tfDataRecalcCounter >= tfDataReloadInterval) {
        shouldReloadTFData = true;
        g_tfDataRecalcCounter = 0;
    } else {
        g_tfDataRecalcCounter++;
    }
    
    // ---------------------------------------------------------------
    // barsToLoad = max(min_bars_required di tutti i TF) * scale(H) (buffer statistico)
    // Usiamo il max tra tutti i periodi organici gia calcolati
    // min_bars_required = longest period + buffer organico (calcolato in CalculateOrganicPeriods)
    // ---------------------------------------------------------------=
    int maxPeriodNeeded = MathMax(g_organic_M5.min_bars_required, 
                          MathMax(g_organic_H1.min_bars_required,
                          MathMax(g_organic_H4.min_bars_required, g_organic_D1.min_bars_required)));
    // Buffer = periodo max * scale(H) (per avere overlap statistico)
    int barsToLoad = (int)MathRound(maxPeriodNeeded * GetOrganicScale(g_hurstGlobal));
    // Minimo = GetBufferXLarge() barre (~48-68)
    int minBarsOrganic = GetBufferXLarge();
    barsToLoad = MathMax(barsToLoad, minBarsOrganic);
    
    //  USA TUTTE LE BARRE DISPONIBILI - no limiti artificiali
    int barsAvailable = Bars(_Symbol, PERIOD_M5);
    
    // Se servono pi barre di quelle disponibili, usa il massimo disponibile
    if (barsToLoad > barsAvailable - 10) {
        barsToLoad = barsAvailable - 10;  // Margine sicurezza per evitare boundary issues
    }
    
    //  MINIMO GARANTITO: almeno 100 barre per analisi statistica significativa (se disponibili)
    barsToLoad = MathMax(barsToLoad, MathMin(100, barsAvailable - 10));
    
    // USA CACHE O RICARICA
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
        //  USA CACHE - Aggiorna SOLO l'ultima barra per ogni TF
        m5Loaded = UpdateLastBar(PERIOD_M5, tfData_M5);
        h1Loaded = UpdateLastBar(PERIOD_H1, tfData_H1);
        h4Loaded = UpdateLastBar(PERIOD_H4, tfData_H4);
        d1Loaded = UpdateLastBar(PERIOD_D1, tfData_D1);
        
        //  FIX: Se update cache fallisce, forza reload completo per recuperare
        if (!m5Loaded || !h1Loaded || !h4Loaded || !d1Loaded) {
            static int cacheFailCount = 0;
            cacheFailCount++;
            if (cacheFailCount <= 3 || cacheFailCount % 20 == 0) {
                PrintFormat("[DATA RECOVER #%d] Cache update fallito - forzo RELOAD completo", cacheFailCount);
            }
            // Forza reload completo per ripristinare isDataReady
            m5Loaded = LoadTimeFrameData(PERIOD_M5, tfData_M5, barsToLoad);
            h1Loaded = LoadTimeFrameData(PERIOD_H1, tfData_H1, barsToLoad);
            h4Loaded = LoadTimeFrameData(PERIOD_H4, tfData_H4, barsToLoad);
            d1Loaded = LoadTimeFrameData(PERIOD_D1, tfData_D1, barsToLoad);
        }
        
        if (g_enableLogsEffective) {
            PrintFormat("[DATA] CACHE USATA (%d/%d) | Aggiornata ultima barra",
                g_tfDataRecalcCounter, tfDataReloadInterval);
        }
    }
    
    // M5 e' obbligatorio (TF operativo), gli altri sono opzionali
    if (!m5Loaded) {
        // FIX: Log SEMPRE attivo per diagnostica blocchi
        static int m5FailCount = 0;
        m5FailCount++;
        if (m5FailCount <= 5 || m5FailCount % 50 == 0) {
            PrintFormat("[ERROR CRITICO #%d] M5 obbligatorio non disponibile - EA BLOCCATO!", m5FailCount);
        }
        return;
    }
    
    // Imposta flag globali TF attivi (usati da ExecuteTradingLogic)
    g_vote_M5_active = EnableVote_M5 && m5Loaded;
    g_vote_H1_active = EnableVote_H1 && h1Loaded;
    g_vote_H4_active = EnableVote_H4 && h4Loaded;
    g_vote_D1_active = EnableVote_D1 && d1Loaded;
    
    // Almeno un TF deve essere attivo
    if (!g_vote_M5_active && !g_vote_H1_active && !g_vote_H4_active && !g_vote_D1_active) {
        // FIX: Log SEMPRE attivo per diagnostica blocchi
        static int noTFCount = 0;
        noTFCount++;
        if (noTFCount <= 5 || noTFCount % 50 == 0) {
            PrintFormat("[ERROR CRITICO #%d] Nessun TF attivo - EA BLOCCATO! Enable: M5=%d H1=%d H4=%d D1=%d",
                noTFCount, EnableVote_M5, EnableVote_H1, EnableVote_H4, EnableVote_D1);
        }
        return;
    }
    
    // ---------------------------------------------------------------
    // CONTROLLO DATI ORGANICI PRONTI
    // L'EA NON entra a mercato finche' non ha abbastanza barre storiche
    // Controlla solo i TF attivi (caricati E abilitati)
    // ---------------------------------------------------------------
    bool allDataReady = true;
    if (g_vote_M5_active && !tfData_M5.isDataReady) allDataReady = false;
    if (g_vote_H1_active && !tfData_H1.isDataReady) allDataReady = false;
    if (g_vote_H4_active && !tfData_H4.isDataReady) allDataReady = false;
    if (g_vote_D1_active && !tfData_D1.isDataReady) allDataReady = false;
    
    if (!allDataReady) {
        // FIX: Log SEMPRE attivo (anche in backtest) per diagnostica blocchi
        static int dataNotReadyCount = 0;
        dataNotReadyCount++;
        if (dataNotReadyCount <= 5 || dataNotReadyCount % 100 == 0) {
            PrintFormat("[ORGANIC BLOCK #%d] Dati non pronti: M5=%d H1=%d H4=%d D1=%d (attivo: M5=%d H1=%d H4=%d D1=%d)",
                dataNotReadyCount,
                tfData_M5.isDataReady ? 1 : 0, tfData_H1.isDataReady ? 1 : 0,
                tfData_H4.isDataReady ? 1 : 0, tfData_D1.isDataReady ? 1 : 0,
                g_vote_M5_active ? 1 : 0, g_vote_H1_active ? 1 : 0,
                g_vote_H4_active ? 1 : 0, g_vote_D1_active ? 1 : 0);
        }
        return;
    }
    
    // LOG VALORI ORGANICI CALCOLATI (sempre visibile se abilitato)
    if (g_enableLogsEffective) {
        static datetime lastOrganicLogTime = 0;
        datetime currentTime = TimeCurrent();
        
        // Log organico ogni naturalPeriod * scale(H) secondi (derivato dai DATI!)
        // Usiamo il naturalPeriod di M5 * 60 (secondi per barra) * scale(H)
        int logIntervalSeconds = (int)MathRound(g_organic_M5.naturalPeriod * 60 * GetOrganicScale(g_hurstGlobal));
        // Minimo = 16 secondi
        int minLogInterval = GetBufferMedium();  // 16
        logIntervalSeconds = MathMax(minLogInterval, logIntervalSeconds);
        
        if (currentTime - lastOrganicLogTime >= logIntervalSeconds) {
            lastOrganicLogTime = currentTime;
            
            Print("");
            Print("---------------------------------------------------------------");
            Print("VALORI ORGANICI CALCOLATI DINAMICAMENTE");
            Print("---------------------------------------------------------------");
            
            if (g_vote_M5_active && ArraySize(tfData_M5.atr) > 0 && ArraySize(tfData_M5.adx) > 0) {
                PrintFormat("[M5] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + decay*std=%.1f)",
                    tfData_M5.atr[ArraySize(tfData_M5.atr)-1], tfData_M5.atr_avg,
                    tfData_M5.adx[ArraySize(tfData_M5.adx)-1], tfData_M5.adx_threshold,
                    tfData_M5.adx_avg, tfData_M5.adx_stddev);
            }
            if (g_vote_H1_active && ArraySize(tfData_H1.atr) > 0 && ArraySize(tfData_H1.adx) > 0) {
                PrintFormat("[H1] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + decay*std=%.1f)",
                    tfData_H1.atr[ArraySize(tfData_H1.atr)-1], tfData_H1.atr_avg,
                    tfData_H1.adx[ArraySize(tfData_H1.adx)-1], tfData_H1.adx_threshold,
                    tfData_H1.adx_avg, tfData_H1.adx_stddev);
            }
            if (g_vote_H4_active && ArraySize(tfData_H4.atr) > 0 && ArraySize(tfData_H4.adx) > 0) {
                PrintFormat("[H4] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + decay*std=%.1f)",
                    tfData_H4.atr[ArraySize(tfData_H4.atr)-1], tfData_H4.atr_avg,
                    tfData_H4.adx[ArraySize(tfData_H4.adx)-1], tfData_H4.adx_threshold,
                    tfData_H4.adx_avg, tfData_H4.adx_stddev);
            }
            if (g_vote_D1_active && ArraySize(tfData_D1.atr) > 0 && ArraySize(tfData_D1.adx) > 0) {
                PrintFormat("[D1] ATR: corrente=%.5f avg=%.5f | ADX: corrente=%.1f soglia=%.1f (avg=%.1f + decay*std=%.1f)",
                    tfData_D1.atr[ArraySize(tfData_D1.atr)-1], tfData_D1.atr_avg,
                    tfData_D1.adx[ArraySize(tfData_D1.adx)-1], tfData_D1.adx_threshold,
                    tfData_D1.adx_avg, tfData_D1.adx_stddev);
            }
            
            Print("---------------------------------------------------------------");
            Print("");
        }
    }
    
    // Logica di trading
    if (g_enableLogsEffective) Print("[TRADE] Avvio logica di trading...");
    
    //  DIAGNOSTICA PERIODICA (sempre attiva, anche in backtest)
    // Stampa stato completo ogni 100 barre per capire blocchi
    static int barCount = 0;
    barCount++;
    // Protezione overflow
    if (barCount > 1000000) barCount = 101;
    if (barCount == 1 || barCount == 10 || barCount == 50 || barCount % 100 == 0) {
        PrintFormat("[DIAG BAR #%d] TF attivi: M5=%d H1=%d H4=%d D1=%d | DataReady: M5=%d H1=%d H4=%d D1=%d",
            barCount,
            g_vote_M5_active ? 1 : 0, g_vote_H1_active ? 1 : 0, 
            g_vote_H4_active ? 1 : 0, g_vote_D1_active ? 1 : 0,
            tfData_M5.isDataReady ? 1 : 0, tfData_H1.isDataReady ? 1 : 0,
            tfData_H4.isDataReady ? 1 : 0, tfData_D1.isDataReady ? 1 : 0);
        PrintFormat("[DIAG BAR #%d] Hurst: H=%.3f Centro=%.3f Stdev=%.4f | TradeScore=%.4f vs Soglia=%.4f -> %s",
            barCount, g_hurstComposite, g_hurstCenter, g_hurstStdev,
            g_hurstTradeScore, g_tradeScoreThreshold,
            g_hurstAllowTrade ? "TRADE PERMESSO" : "TRADE BLOCCATO");
    }
    
    ExecuteTradingLogic();
    if (g_enableLogsEffective) {
        Print("[TRADE] Elaborazione completata");
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
    int decisionDir = (voteResult != 0) ? voteResult : (g_lastHurstSoftSuppressed ? g_lastDominantDirection : 0);
    string voteStr = (decisionDir == 1) ? "BUY" : ((decisionDir == -1) ? "SELL" : "NEUTRAL");
    if (g_enableLogsEffective) {
        PrintFormat("[VOTE] Risultato: %s (score raw: %d)", voteStr, voteResult);
    }

    // Entry attempt = c'e' un segnale (voteResult!=0) oppure soft-hurst ha soppresso un'entry (base ok, eff no)
    bool entryAttempt = (voteResult != 0) || g_lastHurstSoftSuppressed;

    // Helper: contesto compatto non ripetitivo per debug
    string ctx = "";
    if (entryAttempt) {
        ctx = StringFormat(" | score=%.1f%% thr=%.1f%% eff=%.1f%%", g_lastScorePct, g_lastThresholdBasePct, g_lastThresholdEffPct);
        if (EnableHurstFilter) {
            string hState = g_hurstReady ? (g_hurstAllowTrade ? "OK" : "BLOCK") : "NR";
            ctx += StringFormat(" | Hts=%.4f/%.4f:%s", g_hurstTradeScore, g_tradeScoreThreshold, hState);
        }
        if (g_lastHurstSoftActive) {
            ctx += StringFormat(" | Hsoft x%.2f", g_lastHurstSoftMult);
        }
        if (g_lastTFCoherenceActive) {
            if (g_lastTFCoherenceBlocked) {
                ctx += StringFormat(" | TFcoh=BLOCK (conf=%d sup=%d)", g_lastTFCoherenceConflictCount, g_lastTFCoherenceSupportCount);
            } else if (g_lastTFCoherenceMult > 1.0001) {
                ctx += StringFormat(" | TFcoh x%.2f (conf=%d sup=%d)", g_lastTFCoherenceMult, g_lastTFCoherenceConflictCount, g_lastTFCoherenceSupportCount);
            } else {
                ctx += StringFormat(" | TFcoh OK (conf=%d sup=%d)", g_lastTFCoherenceConflictCount, g_lastTFCoherenceSupportCount);
            }
        }
    }
    
    // Controlla se deve eseguire trades
    if (!enableTrading) {
        if (EnableLogs && entryAttempt) PrintFormat("[DECISION] %s | NO ENTRY: trading disabled (enableTrading=false)%s", voteStr, ctx);
        return;
    }
    
    //  VERIFICA PERMESSI TRADING TERMINALE/BROKER
    if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
        if (EnableLogs && entryAttempt) PrintFormat("[DECISION] %s | NO ENTRY: terminal trade not allowed%s", voteStr, ctx);
        return;
    }
    if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) {
        if (EnableLogs && entryAttempt) PrintFormat("[DECISION] %s | NO ENTRY: EA trade not allowed (AutoTrading)%s", voteStr, ctx);
        return;
    }
    
    //  VERIFICA SIMBOLO TRADABILE
    long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
    if (tradeMode == SYMBOL_TRADE_MODE_DISABLED) {
        if (EnableLogs && entryAttempt) PrintFormat("[DECISION] %s | NO ENTRY: symbol not tradable (trade mode disabled)%s", voteStr, ctx);
        return;
    }
    
    // Ottieni prezzo corrente
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double spread = ask - bid;
    double spreadPts = (spread > 0 && _Point > 0) ? (spread / _Point) : 0.0;
    if (entryAttempt) {
        ctx += StringFormat(" | spr=%.1fpt", spreadPts);
    }
    
    // Filtro spread
    if (voteResult != 0 && MaxSpread > 0 && spread > MaxSpread * _Point) {
        if (EnableLogs) PrintFormat("[DECISION] %s | NO ENTRY: spread too high (%.1fpt > %.1fpt max)%s", voteStr, spreadPts, MaxSpread, ctx);
        return;
    }
    
    // Conta posizioni aperte
    int openPositions = CountOpenPositions();
    if (entryAttempt) {
        if (MaxOpenTrades > 0) ctx += StringFormat(" | pos=%d/%d", openPositions, MaxOpenTrades);
        else ctx += StringFormat(" | pos=%d", openPositions);
    }
    
    if (MaxOpenTrades > 0 && openPositions >= MaxOpenTrades) {
        // FIX: Log SEMPRE quando max posizioni raggiunto
        static int maxPosBlockCount = 0;
        maxPosBlockCount++;
        if (maxPosBlockCount <= 3 || maxPosBlockCount % 20 == 0) {
            PrintFormat("[TRADE BLOCK MaxPos #%d] Posizioni: %d/%d - skip", maxPosBlockCount, openPositions, MaxOpenTrades);
        }
        if (EnableLogs && entryAttempt) PrintFormat("[DECISION] %s | NO ENTRY: max positions%s", voteStr, ctx);
        return;
    }
    
    // ---------------------------------------------------------------
    //  FILTRO HURST NO-TRADE ZONE
    // Se il mercato e' in regime "random" (H ~= centro storico), i segnali sono rumore
    // Blocca nuovi trade ma permette gestione posizioni esistenti
    //  FIX: Log solo se c'era un segnale valido da bloccare
    // ---------------------------------------------------------------
    if (voteResult != 0 && !IsTradeAllowedByHurst()) {
        // FIX: Log SEMPRE quando segnale bloccato (anche in backtest) per diagnostica
        // Log throttle: massimo ogni 10 blocchi per evitare spam
        static int blockCount = 0;
        blockCount++;
        if (blockCount <= 3 || blockCount % 10 == 0) {
            PrintFormat("[HURST BLOCK #%d] %s bloccato: TradeScore=%.4f < Soglia=%.4f | H=%.3f Centro=%.3f Stdev=%.4f", 
                blockCount,
                voteResult == 1 ? "BUY" : "SELL", 
                g_hurstTradeScore, g_tradeScoreThreshold,
                g_hurstComposite, g_hurstCenter, g_hurstStdev);
        }
        if (EnableLogs) {
            PrintFormat("[DECISION] %s | NO ENTRY: hurst filter hard block%s", voteStr, ctx);
        }
        return;
    }

    // ---------------------------------------------------------------
    //  CIRCUIT BREAKER (Letter C)
    // Blocca SOLO nuove entry se:
    // - Operational breaker attivo (troppe failure tecniche)
    // - Performance breaker attivo (streak loss / winrate bassa)
    // ---------------------------------------------------------------
    if (voteResult != 0) {
        string cbReason = "";
        int cbRemain = 0;
        if (!CB_AllowNewEntries(cbReason, cbRemain)) {
            if (EnableLogs) PrintFormat("[DECISION] %s | NO ENTRY: circuit breaker (%s, rem=%ds)%s", voteStr, cbReason, cbRemain, ctx);
            static int cbBlockCount = 0;
            cbBlockCount++;
            datetime now = TimeCurrent();
            // Throttle: log max 1/min o su primi eventi
            if (cbBlockCount <= 3 || g_cbLastLogTime == 0 || (now - g_cbLastLogTime) >= 60) {
                int opErr = 0, opWin = 0, opRemain = 0;
                CB_GetOperationalSnapshot(now, opErr, opWin, opRemain);

                int perfCount = 0, perfWins = 0, perfRemain = 0, perfLossStreak = 0;
                double perfNet = 0.0, perfWR = 0.0;
                CB_GetPerformanceSnapshot(perfCount, perfWins, perfNet, perfWR, perfLossStreak, perfRemain);

                PrintFormat("[CB BLOCK #%d] %s bloccato (%s) rem=%ds | OP: err=%d/%d win=%ds rem=%ds | PERF: N=%d wins=%d WR=%.1f%% net=%.2f streakL=%d rem=%ds",
                    cbBlockCount,
                    voteResult == 1 ? "BUY" : "SELL",
                    cbReason,
                    cbRemain,
                    opErr, OpMaxErrorsInWindow, opWin, opRemain,
                    perfCount, perfWins, perfWR, perfNet, perfLossStreak, perfRemain);
                g_cbLastLogTime = now;
            }
            return;
        }
    }

    // TF Coherence (hard block): blocco finale prima di inviare ordini
    if (EnableTFCoherenceFilter && TFCoherenceHardBlock && voteResult != 0 && g_lastTFCoherenceBlocked) {
        if (EnableLogs) PrintFormat("[DECISION] %s | NO ENTRY: TF coherence hard block%s", voteStr, ctx);
        return;
    }

    // Caso speciale: soft-hurst ha soppresso un'entry (base ok, eff no)
    if (g_lastHurstSoftSuppressed && voteResult == 0) {
        if (EnableLogs) PrintFormat("[DECISION] %s | NO ENTRY: hurst soft raised threshold%s", voteStr, ctx);
        return;
    }

    // Riepilogo Soft Hurst: utile nei backtest lunghi (throttle per N barre)
    if (EnableLogs && EnableHurstFilter && EnableHurstSoftMode && HurstSoftSummaryEveryBars > 0) {
        static int softBarCounter = 0;
        static bool softWasActive = false;
        softBarCounter++;
        if (softBarCounter > 1000000) softBarCounter = 1;

        bool softActiveNow = g_lastHurstSoftActive;
        if (softActiveNow && !softWasActive) {
            PrintFormat("[HURST SOFT] ATTIVO%s | TradeScore=%.4f < Thr=%.4f",
                GetHurstSoftDecisionTag(true), g_hurstTradeScore, g_tradeScoreThreshold);
        } else if (!softActiveNow && softWasActive) {
            PrintFormat("[HURST SOFT] DISATTIVO (no penalty) | TradeScore=%.4f >= Thr=%.4f",
                g_hurstTradeScore, g_tradeScoreThreshold);
        }

        if (softActiveNow && (softBarCounter == 1 || (softBarCounter % HurstSoftSummaryEveryBars) == 0)) {
            PrintFormat("[HURST SOFT] snapshot%s | TradeScore=%.4f < Thr=%.4f | H=%.3f Centro=%.3f Stdev=%.4f",
                GetHurstSoftDecisionTag(true), g_hurstTradeScore, g_tradeScoreThreshold,
                g_hurstComposite, g_hurstCenter, g_hurstStdev);
        }
        softWasActive = softActiveNow;
    }

    // Log sblocco (una volta) quando cooldown termina
    CB_LogUnblockTransitions();
    
    // Esegui trades basati su voto
    if (voteResult == -1) {
        if (EnableLogs) PrintFormat("[DECISION] %s | ENTRY allowed: sending order%s", voteStr, ctx);
        if (g_enableLogsEffective) Print("[TRADE] SEGNALE SELL CONFERMATO - Apertura ordine...");
        OpenSellOrder();
    }
    else if (voteResult == 1) {
        if (EnableLogs) PrintFormat("[DECISION] %s | ENTRY allowed: sending order%s", voteStr, ctx);
        if (g_enableLogsEffective) Print("[TRADE] SEGNALE BUY CONFERMATO - Apertura ordine...");
        OpenBuyOrder();
    }
    else {
        // Nessun segnale: evita spam. Logga solo ogni tanto (utile in backtest per vedere che l'EA e' vivo).
        if (EnableLogs) {
            static int noSignalCount = 0;
            noSignalCount++;
            if (noSignalCount == 1 || noSignalCount == 10 || noSignalCount % 50 == 0) {
                PrintFormat("[DECISION] %s | NO ENTRY: no signal", voteStr);
            }
        }
    }
    // FIX: Rimosso log "Nessun segnale - in attesa..." - troppo verboso (ogni 5 min)
}

//+------------------------------------------------------------------+
//| Conta posizioni aperte                                           |
//|  FIX: Aggiunta gestione errori per sincronizzazione            |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    //  FIX: Retry loop per gestire race condition (posizioni che cambiano durante iterazione)
    int maxRetries = 3;
    
    for (int attempt = 0; attempt < maxRetries; attempt++) {
        int count = 0;
        bool hadError = false;
        int skippedPositions = 0;  // FIX: Conta posizioni saltate per diagnostica
        
        //  FIX: Usa Magic cachato invece di ricalcolarlo ogni volta
        int uniqueMagic = g_uniqueMagicNumber;
        int total = PositionsTotal();
        
        for (int i = total - 1; i >= 0; i--) {
            // Reset errore prima di ogni operazione
            ResetLastError();
            
            ulong ticket = PositionGetTicket(i);
            
            //  FIX: Gestione errore di sincronizzazione
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
                        PrintFormat("[CountOpenPositions] Errore %d su posizione %d (tentativo %d)", err, i, attempt + 1);
                    }
                }
                // err == 0 con ticket == 0: posizione gia' chiusa, skip silenzioso
                continue;
            }
            
            // Seleziona esplicitamente per ticket per garantire consistenza
            if (!PositionSelectByTicket(ticket)) {
                continue;  // Posizione non piu' valida
            }
            
            if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
                PositionGetInteger(POSITION_MAGIC) == uniqueMagic) {
                count++;
            }
        }
        
        //  FIX: Log se troppe posizioni saltate (possibile anomalia)
        if (skippedPositions > 2 && g_enableLogsEffective) {
            PrintFormat("[CountOpenPositions] %d posizioni saltate (tentativo %d)", skippedPositions, attempt + 1);
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
        Print("[CountOpenPositions] Troppi errori - ritorno 0 per sicurezza");
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
        // Log throttle: naturalPeriod * secondi per barra / scale(H) (derivato dai DATI!)
        // FIX: Protezione quando naturalPeriod = 0
        int naturalPeriod = MathMax(1, g_organic_M5.naturalPeriod);  // Minimo 1 per evitare divisione per zero
        int throttleSeconds = (int)MathRound(naturalPeriod * 60 * GetOrganicDecay(g_hurstGlobal));
        // Minimo = 8 secondi
        int minThrottle = GetBufferSmall();  // 8
        throttleSeconds = MathMax(minThrottle, throttleSeconds);
        
        if (now - lastVoteDisabledLog >= throttleSeconds || lastVoteDisabledLog == 0) {
            Print("[VOTE] Sistema voti indicatori DISATTIVATO (EnableIndicatorVoteSystem=false) - decisione neutra");
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
    // cATR e cADX rimossi perche' ATR/ADX non sono direzionali
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
        //  Usa centri EMPIRICI dalla struct tfData invece di costanti hardcoded!
        cEMA  = enableEMA         && (price > emaBuf[0]);
        cRSI  = enableRSI         && (rsiBuf[0] > tfData_M5.rsi_center);
        cMACD = enableMACD        && (macdBuf[0] > sigBuf[0]);
        // BB: sopra la banda media = BUY (coerente con CalculateSignalScore)
        double bbMiddle = (bbUp[0] + bbLow[0]) / 2.0;
        cBB   = enableBB          && (price > bbMiddle);
        // NOTA: ATR e ADX sono indicatori NON direzionali, usati solo come filtri (non partecipano al voto)

        //  Controlli array bounds per indicatori da struct tfData
        cHeikin = false;
        if (enableHeikin && ArraySize(tfData_M5.ha_close) > latestIdxM5 && ArraySize(tfData_M5.ha_open) > latestIdxM5) {
            cHeikin = (tfData_M5.ha_close[latestIdxM5] > tfData_M5.ha_open[latestIdxM5]);
        }
        
        cOBV = false;
        if (enableOBV && ArraySize(tfData_M5.obv) > latestIdxM5 && latestIdxM5 >= 1) {
            cOBV = (tfData_M5.obv[latestIdxM5] >= tfData_M5.obv[latestIdxM5 - 1]);
        }
        
        // NUOVI INDICATORI TREND (v1.1)
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
        
        //  Calcola score M5 normalizzato tramite funzione unificata con valori ORGANICI
        // NOTA: Le variabili cXXX sopra sono usate solo per il log dettagliato,
        //       lo score effettivo viene da CalculateSignalScore che usa normalizzazione continua
        scoreM5 = CalculateSignalScore(tfData_M5, "M5");
        
        // Log M5 score calcolato
        if (g_enableLogsEffective) {
            PrintFormat("[M5] Score normalizzato: %+.2f (peso organico TF: %.2f)", scoreM5, tfData_M5.organic.weight);
        }
    }
    
    // Calcolo consenso multi-timeframe con pesi e threshold specifici per ogni TF
    // OTTIMIZZAZIONE: Calcola score SOLO per TF attivi (usa flag globali)
    if (!g_vote_M5_active) scoreM5 = 0;  // M5 gia' calcolato sopra se attivo
    
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
    
    //  LOG DETTAGLIATO INDICATORI PER OGNI TIMEFRAME
    if (g_enableLogsEffective) {
        Print("\n========== ANALISI INDICATORI DETTAGLIATA (v1.1) ==========");
        
        // M5 INDICATORS LOG
        if (g_vote_M5_active) {
            Print("\n--- M5 (OPERATIVO) ---");
            PrintFormat("  Peso organico TF: %.2f", tfData_M5.organic.weight);
            
            // --- TREND PRIMARIO (VOTANO) ---
            Print("  --- TREND PRIMARIO (votano) ---");
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f -> %s (%s)",
                price, emaBuf[0], cEMA ? "BUY" : "SELL", enableEMA ? "VOTA" : "disattivo");
            PrintFormat("  MACD: %.6f vs Signal=%.6f -> %s (%s)",
                macdBuf[0], sigBuf[0], cMACD ? "BUY" : "SELL", enableMACD ? "VOTA" : "disattivo");
            double psar_val = (ArraySize(tfData_M5.psar) > latestIdxM5) ? tfData_M5.psar[latestIdxM5] : 0;
            PrintFormat("  PSAR: Price=%.5f vs SAR=%.5f -> %s (%s)",
                price, psar_val, cPSAR ? "BUY" : "SELL", enablePSAR ? "VOTA" : "disattivo");
            double sma_fast = (ArraySize(tfData_M5.sma_fast) > latestIdxM5) ? tfData_M5.sma_fast[latestIdxM5] : 0;
            double sma_slow = (ArraySize(tfData_M5.sma_slow) > latestIdxM5) ? tfData_M5.sma_slow[latestIdxM5] : 0;
            PrintFormat("  SMA Cross: Fast=%.5f vs Slow=%.5f -> %s (%s)",
                sma_fast, sma_slow, cSMA ? "BUY" : "SELL", enableSMA ? "VOTA" : "disattivo");
            PrintFormat("  Ichimoku: %s (%s)",
                cIchi ? "Sopra Cloud + TK>KJ" : "Sotto Cloud o TK<KJ", enableIchimoku ? "VOTA" : "disattivo");
            
            // --- TREND FILTER ---
            Print("  --- TREND FILTER ---");
            PrintFormat("  ADX: %.2f vs Soglia=%.2f -> %s (vota con +DI/-DI, %s)",
                adxBuf[0], tfData_M5.adx_threshold, adxBuf[0] > tfData_M5.adx_threshold ? "TREND" : "NO TREND", enableADX ? "VOTA" : "disattivo");
            
            // --- TREND SUPPORT (VOTANO) ---
            Print("  --- TREND SUPPORT (votano) ---");
            double ha_close_log = (ArraySize(tfData_M5.ha_close) > latestIdxM5) ? tfData_M5.ha_close[latestIdxM5] : 0;
            double ha_open_log = (ArraySize(tfData_M5.ha_open) > latestIdxM5) ? tfData_M5.ha_open[latestIdxM5] : 0;
            PrintFormat("  Heikin Ashi: HAclose=%.5f vs HAopen=%.5f -> %s (%s)",
                ha_close_log, ha_open_log, cHeikin ? "BUY" : "SELL", enableHeikin ? "VOTA" : "disattivo");
            PrintFormat("  BB: Price=%.5f vs Middle=%.5f -> %s (%s)",
                price, (bbUp[0] + bbLow[0]) / 2.0, cBB ? "BUY" : "SELL", enableBB ? "VOTA" : "disattivo");
            
            Print("  === MEAN-REVERSION (analisi H1 -> voto combinato) ===");
            Print("  Nota: RSI/Stoch/OBV analizzati su H1, voto applicato a tutti TF");
            PrintFormat("  RSI M5: %.1f%% | Stoch K: %.1f%% | OBV: %s",
                rsiBuf[0], stochK, 
                (ArraySize(tfData_M5.obv) > latestIdxM5 && latestIdxM5 >= 1 && 
                 tfData_M5.obv[latestIdxM5] > tfData_M5.obv[latestIdxM5-1]) ? "UP" : "DOWN");
            
            PrintFormat("  SCORE M5: %.2f", scoreM5);
        } else {
            Print("  M5 Score:  N/D (DISATTIVATO)");
        }
    }
    
    // H1 INDICATORS - Usa solo indicatori esistenti in TimeFrameData
    if (g_vote_H1_active && g_enableLogsEffective) {
        int h1_idx = ArraySize(tfData_H1.rsi) - 1;
        if (h1_idx < 0) {
            Print("\n--- H1: DATI NON DISPONIBILI ---");
        } else {
            Print("\n--- H1 (INTERMEDIO) ---");
            PrintFormat("  Peso organico TF: %.2f", tfData_H1.organic.weight);
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
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f -> %s (VOTA)", price, h1_ema, (price > h1_ema) ? "BUY" : "SELL");
            PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f -> %s (FILTER)", h1_adx, tfData_H1.adx_threshold, (h1_adx > tfData_H1.adx_threshold) ? "TREND" : "NO TREND");
            PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f -> %s (VOTA)", h1_ha_close, h1_ha_open, (h1_ha_close > h1_ha_open) ? "BUY" : "SELL");
            // MEAN-REVERSION (valori H1 usati per detection combinata)
            PrintFormat("  RSI H1: %.1f%% | OBV: %s (usati per voto combinato)",
                h1_rsi, (h1_obv > h1_obv_prev) ? "UP" : "DOWN");
            PrintFormat("  SCORE H1: %.2f", scoreH1);
        }
    } else if (g_enableLogsEffective) {
        Print("  H1 Score:  N/D (DISATTIVATO)");
    }
    
    // H4 INDICATORS - Usa solo indicatori esistenti in TimeFrameData
    if (g_vote_H4_active && g_enableLogsEffective) {
        int h4_idx = ArraySize(tfData_H4.rsi) - 1;
        if (h4_idx < 0) {
            Print("\n--- H4: DATI NON DISPONIBILI ---");
        } else {
            Print("\n--- H4 (SWING) ---");
            PrintFormat("  Peso organico TF: %.2f", tfData_H4.organic.weight);
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
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f -> %s (VOTA)", price, h4_ema, (price > h4_ema) ? "BUY" : "SELL");
            PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f -> %s (FILTER)", h4_adx, tfData_H4.adx_threshold, (h4_adx > tfData_H4.adx_threshold) ? "TREND" : "NO TREND");
            PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f -> %s (VOTA)", h4_ha_close, h4_ha_open, (h4_ha_close > h4_ha_open) ? "BUY" : "SELL");
            // MEAN-REVERSION (analizzato su H1, vedi pannello combinato)
            Print("  Mean-Rev: vedi pannello combinato (analisi H1)");
            PrintFormat("  SCORE H4: %.2f", scoreH4);
        }
    } else if (g_enableLogsEffective) {
        Print("  H4 Score:  N/D (DISATTIVATO)");
    }
    
    // D1 INDICATORS - Usa solo indicatori esistenti in TimeFrameData
    if (g_vote_D1_active && g_enableLogsEffective) {
        int d1_idx = ArraySize(tfData_D1.rsi) - 1;
        if (d1_idx < 0) {
            Print("\n--- D1: DATI NON DISPONIBILI ---");
        } else {
            Print("\n--- D1 (TREND LUNGO) ---");
            PrintFormat("  Peso organico TF: %.2f", tfData_D1.organic.weight);
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
            PrintFormat("  EMA: Price=%.5f vs EMA=%.5f -> %s (VOTA)", price, d1_ema, (price > d1_ema) ? "BUY" : "SELL");
            PrintFormat("  ADX: %.2f vs Soglia Organica=%.2f -> %s (FILTER)", d1_adx, tfData_D1.adx_threshold, (d1_adx > tfData_D1.adx_threshold) ? "TREND" : "NO TREND");
            PrintFormat("  Heikin: HAclose=%.5f vs HAopen=%.5f -> %s (VOTA)", d1_ha_close, d1_ha_open, (d1_ha_close > d1_ha_open) ? "BUY" : "SELL");
            // MEAN-REVERSION (analizzato su H1, vedi pannello combinato)
            Print("  Mean-Rev: vedi pannello combinato (analisi H1)");
            PrintFormat("  SCORE D1: %.2f", scoreD1);
        }
    } else if (g_enableLogsEffective) {
        Print("  D1 Score:  N/D (DISATTIVATO)");
    }
    
    if (g_enableLogsEffective) {
        Print("\n========== SOMMA TOTALE MULTI-TIMEFRAME ==========");
    }
    
    //  SOMMA TOTALE degli score di tutti i timeframe attivi
    double totalScore = 0.0;
    if (g_vote_M5_active) totalScore += scoreM5;
    if (g_vote_H1_active) totalScore += scoreH1;
    if (g_vote_H4_active) totalScore += scoreH4;
    if (g_vote_D1_active) totalScore += scoreD1;
    
    // 
    //  DETECTOR INVERSIONE: Aggiorna tutti i segnali MEAN-REVERSION
    // 
    int momentumSignal = UpdateScoreMomentum(totalScore);
    int regimeSignal = UpdateRegimeChange();
    int divergenceSignal = UpdateRSIDivergence();
    
    //  NUOVI DETECTOR MEAN-REVERSION (v1.1)
    int stochExtremeSignal = UpdateStochasticExtreme();
    int obvDivergenceSignal = UpdateOBVDivergence();
    
    // 
    // v1.1: MEAN-REVERSION = UN SOLO VOTO COMBINATO
    // Combina RSI + Stochastic + OBV in un UNICO segnale data-driven
    // Poi applica questo voto a OGNI TIMEFRAME attivo
    // 
    
    // STEP 1: Calcola segnale combinato (gia fatto in GetReversalSignal)
    // Ma qui vogliamo la versione semplificata per il voto
    double meanRevCombinedStrength = 0.0;
    int meanRevCombinedSignal = 0;  // +1=BUY, -1=SELL, 0=NEUTRO
    
    // PESI ORGANICI Hurst-driven per combinazione
    double scale = GetOrganicScale(g_hurstGlobal);
    double decay = GetOrganicDecay(g_hurstGlobal);
    double w_rsi = scale;         // RSI divergence = peso scale(H) (piu affidabile)
    double w_obv = 1.0;           // OBV divergence = peso 1
    double w_stoch = decay;       // Stochastic = peso decay(H)
    
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
    
    // SOGLIA DA HURST: segnale valido solo se forza >= decay(H) (~0.62 per H=0.7)
    double meanRevThreshold = GetOrganicDecay(g_hurstGlobal);  // Soglia data-driven da Hurst
    if (combinedMax > 0) {
        meanRevCombinedStrength = MathAbs(combinedScore) / combinedMax;
        if (meanRevCombinedStrength >= meanRevThreshold) {
            meanRevCombinedSignal = (combinedScore > 0) ? 1 : -1;
        }
    }
    
    // STEP 2: Applica il VOTO UNICO a OGNI TF attivo
    // Peso = decay(H) * peso_TF (mean-reversion = contrarian, peso ridotto)
    double meanRevScore = 0.0;
    double meanRevMaxScore = 0.0;
    
    // Calcola SEMPRE il max possibile (anche se segnale neutro)
    // Questo serve per mantenere scorePct stabile
    if (enableRSI || enableOBV || enableStoch) {
        if (g_vote_M5_active) meanRevMaxScore += g_organic_M5.weight * decay;
        if (g_vote_H1_active) meanRevMaxScore += g_organic_H1.weight * decay;
        if (g_vote_H4_active) meanRevMaxScore += g_organic_H4.weight * decay;
        if (g_vote_D1_active) meanRevMaxScore += g_organic_D1.weight * decay;
    }
    
    // Applica voto solo se segnale attivo
    if (meanRevCombinedSignal != 0) {
        if (g_vote_M5_active) {
            meanRevScore += meanRevCombinedSignal * meanRevCombinedStrength * g_organic_M5.weight * decay;
        }
        if (g_vote_H1_active) {
            meanRevScore += meanRevCombinedSignal * meanRevCombinedStrength * g_organic_H1.weight * decay;
        }
        if (g_vote_H4_active) {
            meanRevScore += meanRevCombinedSignal * meanRevCombinedStrength * g_organic_H4.weight * decay;
        }
        if (g_vote_D1_active) {
            meanRevScore += meanRevCombinedSignal * meanRevCombinedStrength * g_organic_D1.weight * decay;
        }
    }
    
    // AGGIUNGI MEAN-REVERSION AL TOTALE
    totalScore += meanRevScore;
    
    // LOG DIAGNOSTICO SCORE - SEMPRE VISIBILE
    if (g_enableLogsEffective) {
        // Score trend-following (senza mean-reversion)
        double trendScore = totalScore - meanRevScore;
        PrintFormat("[SCORE] M5: %+.2f | H1: %+.2f | H4: %+.2f | D1: %+.2f | TREND: %+.2f", 
            scoreM5, scoreH1, scoreH4, scoreD1, trendScore);
        
        //  LOG MEAN-REVERSION - SEMPRE VISIBILE (anche se neutro)
        string rsiStatus = "-";
        string obvStatus = "-";
        string stochStatus = "-";
        
        if (enableRSI) {
            if (divergenceSignal > 0) rsiStatus = StringFormat("BUY %.0f%%", g_divergenceStrength*100);
            else if (divergenceSignal < 0) rsiStatus = StringFormat("SELL %.0f%%", g_divergenceStrength*100);
            else rsiStatus = "NEUTRO";
        }
        if (enableOBV) {
            if (obvDivergenceSignal > 0) obvStatus = StringFormat("BUY %.0f%%", g_obvDivergenceStrength*100);
            else if (obvDivergenceSignal < 0) obvStatus = StringFormat("SELL %.0f%%", g_obvDivergenceStrength*100);
            else obvStatus = "NEUTRO";
        }
        if (enableStoch) {
            if (stochExtremeSignal > 0) stochStatus = StringFormat("BUY %.0f%%", g_stochExtremeStrength*100);
            else if (stochExtremeSignal < 0) stochStatus = StringFormat("SELL %.0f%%", g_stochExtremeStrength*100);
            else stochStatus = "NEUTRO";
        }
        
        // Mostra sempre il pannello mean-reversion
        Print("  === MEAN-REVERSION (voto combinato per ogni TF) ===");
        PrintFormat("  RSI: %s | OBV: %s | Stoch: %s", rsiStatus, obvStatus, stochStatus);
        
        if (meanRevCombinedSignal != 0) {
            PrintFormat("  SEGNALE COMBINATO: %s (forza %.0f%% >= soglia %.0f%%)", 
                meanRevCombinedSignal > 0 ? "BUY" : "SELL",
                meanRevCombinedStrength * 100, meanRevThreshold * 100);
            PrintFormat("  VOTO AGGIUNTO: %+.3f su %d TF attivi", meanRevScore, 
                (g_vote_M5_active?1:0) + (g_vote_H1_active?1:0) + (g_vote_H4_active?1:0) + (g_vote_D1_active?1:0));
        } else {
            PrintFormat("  SEGNALE: NEUTRO (forza %.0f%% < soglia %.0f%% oppure nessun segnale)",
                meanRevCombinedStrength * 100, meanRevThreshold * 100);
        }
        
        PrintFormat("[TOTALE] TREND(%+.2f) + MEAN-REV(%+.2f) = %+.2f", 
            trendScore, meanRevScore, totalScore);
        
        if (totalScore > 0)
            Print("  DIREZIONE FINALE: BUY (totalScore > 0)");
        else if (totalScore < 0)
            Print("  DIREZIONE FINALE: SELL (totalScore < 0)");
        else
            Print("  DIREZIONE FINALE: NEUTRO (totalScore = 0)");
        
        Print("======================================================\n");
    }
    
    // ------------------------------------------------------------
    // LOGICA DECISIONALE ORGANICA
    // Score -> Direzione + Soglia percentuale
    // ------------------------------------------------------------
    
    int decision = 0; // 0=no trade, 1=buy, -1=sell
    
    // CALCOLA SCORE MASSIMO POSSIBILE (organico)
    // Ogni indicatore attivo contribuisce peso_TF al massimo (max = 1.0 * peso)
    // Max = num_indicatori_attivi * S(peso_TF_attivi) * 1.0
    double maxScorePossible = 0.0;
    
    // FIX: Conta separatamente indicatori DIREZIONALI e MEAN-REVERSION
    // ADX = FILTER (vota solo se trend), Mean-reversion vota nella direzione inversione
    // v1.1 FIX: Calcola peso TOTALE indicatori considerando le CATEGORIE
    // TREND PRIMARY (peso 1.0): EMA, MACD, PSAR, SMA, Ichimoku
    // TREND SUPPORT (peso decay ~ 0.6): BB, Heikin  
    // TREND FILTER (peso 1.0, condizionale): ADX
    double weightTrendPrimary = 0.0;    // Peso totale indicatori primari
    double weightTrendSupport = 0.0;    // Peso totale indicatori supporto
    double weightTrendFilter = 0.0;     // Peso totale indicatori filtro
    
    // TREND PRIMARY (peso 1.0 ciascuno)
    if (enableEMA) weightTrendPrimary += 1.0;
    if (enableMACD) weightTrendPrimary += 1.0;
    if (enablePSAR) weightTrendPrimary += 1.0;
    if (enableSMA) weightTrendPrimary += 1.0;
    if (enableIchimoku) weightTrendPrimary += 1.0;
    
    // TREND SUPPORT (peso decay(H) ~ 0.6 ciascuno)
    double decayWeight = GetOrganicDecay(g_hurstGlobal);
    if (enableBB) weightTrendSupport += decayWeight;
    if (enableHeikin) weightTrendSupport += decayWeight;
    
    // TREND FILTER (peso 1.0, ma vota solo se ADX > soglia)
    if (enableADX) weightTrendFilter += 1.0;
    
    // Peso TOTALE indicatori per ogni TF = PRIMARY + SUPPORT + FILTER
    double totalIndicatorWeight = weightTrendPrimary + weightTrendSupport + weightTrendFilter;
    
    // Max score TREND = somma dei pesi organici TF * peso totale indicatori (con categoria)
    if (g_vote_M5_active) maxScorePossible += g_organic_M5.weight * totalIndicatorWeight;
    if (g_vote_H1_active) maxScorePossible += g_organic_H1.weight * totalIndicatorWeight;
    if (g_vote_H4_active) maxScorePossible += g_organic_H4.weight * totalIndicatorWeight;
    if (g_vote_D1_active) maxScorePossible += g_organic_D1.weight * totalIndicatorWeight;
    
    // v1.1: AGGIUNGI MAX MEAN-REVERSION (gia' calcolato sopra)
    maxScorePossible += meanRevMaxScore;
    
    // VALIDATO: scorePct sempre >= 0 (MathAbs + divisione protetta)
    double scorePct = (maxScorePossible > 0) ? (MathAbs(totalScore) / maxScorePossible) * 100.0 : 0;
    bool isBuy = (totalScore > 0);
    bool isSell = (totalScore < 0);

    // Salva direzione dominante (anche se poi la decision finale e' 0)
    g_lastDominantDirection = isBuy ? 1 : (isSell ? -1 : 0);
    
    // v1.1: GetReversalSignal per tracciare statistiche (soglia data-driven)
    // I detector sono gia stati chiamati sopra, questa chiamata aggiorna solo il buffer storico
    double reversalStrength = 0.0;
    int reversalSignal = GetReversalSignal(reversalStrength);
    
    // AGGIUNGI SCORE AL BUFFER STORICO (per soglia automatica)
    // INPUT: scorePct >= 0 (validato sopra)
    AddScoreToHistory(scorePct);
    
    // OTTIENI SOGLIA CORRENTE (automatica o manuale, con fallback)
    double currentThreshold = GetCurrentThreshold();

    // OPTION 1 (SOFT HURST): quando il regime e' "random" (TradeScore Hurst sotto soglia),
    // non blocchiamo hard, ma alziamo la soglia effettiva richiesta per entrare.
    double hurstSoftMult = GetHurstSoftThresholdMultiplier();
    double effectiveThreshold = currentThreshold * hurstSoftMult;
    if (effectiveThreshold > 100.0) effectiveThreshold = 100.0;

    // TF COHERENCE: penalizza o blocca in caso di conflitto tra regimi TF
    double tfCohMult = 1.0;
    int tfCohConf = 0;
    int tfCohSup = 0;
    bool tfCohOk = GetTFCoherenceDecision((isBuy ? 1 : (isSell ? -1 : 0)), tfCohMult, tfCohConf, tfCohSup);
    bool tfCohBlocked = EnableTFCoherenceFilter && TFCoherenceHardBlock && !tfCohOk;
    if (!tfCohBlocked) {
        effectiveThreshold *= tfCohMult;
        if (effectiveThreshold > 100.0) effectiveThreshold = 100.0;
    }

    // Salva diagnostica per log DECISION (ExecuteTradingLogic)
    g_lastHurstSoftMult = hurstSoftMult;
    g_lastThresholdBasePct = currentThreshold;
    g_lastThresholdEffPct = effectiveThreshold;
    g_lastScorePct = scorePct;
    g_lastHurstSoftActive = (EnableHurstFilter && EnableHurstSoftMode && (hurstSoftMult > 1.0001));
    bool wouldPassBase = (isBuy && scorePct >= currentThreshold) || (isSell && scorePct >= currentThreshold);
    bool wouldPassEff  = (isBuy && scorePct >= effectiveThreshold) || (isSell && scorePct >= effectiveThreshold);
    g_lastHurstSoftSuppressed = (g_lastHurstSoftActive && wouldPassBase && !wouldPassEff);

    g_lastTFCoherenceActive = EnableTFCoherenceFilter;
    g_lastTFCoherenceMult = tfCohMult;
    g_lastTFCoherenceBlocked = tfCohBlocked;
    g_lastTFCoherenceConflictCount = tfCohConf;
    g_lastTFCoherenceSupportCount = tfCohSup;
    
    // Minimo campioni per soglia automatica = 16 (BUFFER_SIZE_MEDIUM)
    int minSamplesForLog = GetBufferMedium();
    
    // Log se stiamo usando fallback
    if (AutoScoreThreshold && !g_scoreThresholdReady && g_enableLogsEffective) {
        PrintFormat("[VOTE] Soglia auto non pronta, uso fallback manuale: %.1f%% (buffer: %d/%d)", 
            ScoreThreshold, g_scoreHistorySize, minSamplesForLog);
    }
    
    // LOG DIAGNOSTICO
    if (g_enableLogsEffective) {
        // ANALISI: distingui chiaramente il tipo di soglia usata
        string thresholdType;
        if (!AutoScoreThreshold) 
            thresholdType = "MANUALE";
        else if (g_scoreThresholdReady)
            thresholdType = "AUTO";
        else
            thresholdType = StringFormat("FALLBACK:%d/%d", g_scoreHistorySize, minSamplesForLog);
        
        if (hurstSoftMult > 1.0001) {
            PrintFormat("[SCORE DEBUG] Score: %+.2f | Max: %.2f | Pct: %.2f%% | Soglia: %.1f%% (%s) | HurstSoft x%.2f -> Eff=%.1f%%",
                totalScore, maxScorePossible, scorePct, currentThreshold, thresholdType, hurstSoftMult, effectiveThreshold);
        } else {
            PrintFormat("[SCORE DEBUG] Score: %+.2f | Max: %.2f | Pct: %.2f%% | Soglia: %.1f%% (%s)",
                totalScore, maxScorePossible, scorePct, currentThreshold, thresholdType);
        }
        PrintFormat("   Peso indicatori: %.2f (PRIMARY:%.0f + SUPPORT:%.2f + FILTER:%.0f) | Direzione: %s", 
            totalIndicatorWeight, weightTrendPrimary, weightTrendSupport, weightTrendFilter,
            isBuy ? "BUY" : isSell ? "SELL" : "NEUTRA");
    }
    
    // ---------------------------------------------------------------
    // LOGICA DECISIONALE ORGANICA v1.1
    // 
    // NUOVA LOGICA: Mean-reversion VOTA (non blocca)
    // Il mean-reversion aggiunge gia il suo contributo al totalScore
    // nella direzione dell'inversione attesa
    // 
    // REGOLE:
    // 1. totalScore > 0 e scorePct >= soglia ? BUY
    // 2. totalScore < 0 e scorePct >= soglia ? SELL
    // 3. Score sotto soglia ma reversal forte nella stessa dir ? entry anticipato
    // ---------------------------------------------------------------
    
    bool reversalBoost = false;      // True se reversal permette entry anticipato
    
    // STEP 1: Valuta segnale normale (score sopra soglia)
    if (isBuy && scorePct >= effectiveThreshold) {
        decision = 1;
    }
    else if (isSell && scorePct >= effectiveThreshold) {
        decision = -1;
    }
    
    // STEP 2: Score DEBOLE ma REVERSAL FORTE nella stessa direzione - entry anticipato
    if (decision == 0 && reversalSignal != 0 && reversalStrength >= g_reversalThreshold) {
        // Score deve essere almeno nella stessa direzione del reversal
        bool directionMatch = (reversalSignal == 1 && totalScore >= 0) || 
                              (reversalSignal == -1 && totalScore <= 0);
        
        // Soglia ridotta = soglia * decay(H) (circa 60-70% della normale)
        double reversalThreshold = effectiveThreshold * GetOrganicDecay(g_hurstGlobal);
        
        // Log dettagliato analisi entry anticipato
        if (g_enableLogsEffective && (reversalStrength >= g_reversalThreshold || scorePct >= reversalThreshold * 0.8)) {
            PrintFormat("[ENTRY ANTICIPATO %s] Analisi:",
                TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
            PrintFormat("   Reversal: %s strength=%.0f%% (soglia %.0f%% %s)",
                reversalSignal > 0 ? "BUY" : reversalSignal < 0 ? "SELL" : "NONE",
                reversalStrength * 100, g_reversalThreshold * 100,
                reversalStrength >= g_reversalThreshold ? "OK" : "NO");
            PrintFormat("   Score: %.1f%% vs soglia ridotta %.1f%% (%.1f%%  %.3f decay)",
                scorePct, reversalThreshold, effectiveThreshold, GetOrganicDecay(g_hurstGlobal));
            PrintFormat("   Breakdown: Total=%+.3f Trend=%+.3f MeanRev=%+.3f",
                totalScore, totalScore - meanRevScore, meanRevScore);
            PrintFormat("   TF Scores: M5=%+.2f H1=%+.2f H4=%+.2f D1=%+.2f",
                scoreM5, scoreH1, scoreH4, scoreD1);
            PrintFormat("   Match: reversal=%s score=%s -> %s",
                reversalSignal > 0 ? "BUY" : "SELL",
                totalScore >= 0 ? "POS" : "NEG",
                directionMatch ? "OK" : "MISMATCH");
            if (directionMatch && scorePct >= reversalThreshold) {
                PrintFormat("   ENTRY ANTICIPATO ATTIVATO!");
            } else {
                string reason = !directionMatch ? "direzione mismatch" : "score < soglia ridotta";
                PrintFormat("   Entry anticipato non attivato: %s", reason);
            }
        }
        
        if (directionMatch && scorePct >= reversalThreshold) {
            decision = reversalSignal;
            reversalBoost = true;
        }
    }
    
    // ---------------------------------------------------------------
    // LOG UNICO E CHIARO
    // ---------------------------------------------------------------
    if (decision != 0) {
        string decisionText = (decision == 1) ? "BUY" : "SELL";
        
        if (reversalBoost) {
            // Trade ANTICIPATO grazie a reversal
            PrintFormat("[VOTE] %s ANTICIPATO | Score: %.1f%% + Reversal %s (forza %.0f%%)",
                decisionText, scorePct,
                reversalSignal == 1 ? "BULLISH" : "BEARISH", reversalStrength * 100);
        } else if (meanRevScore != 0 && ((meanRevScore > 0 && decision == 1) || (meanRevScore < 0 && decision == -1))) {
            // Trade con contributo mean-reversion concorde
            PrintFormat("[VOTE] %s CONFERMATO | Score: %.1f%% (Mean-Rev: %+.3f concorde)",
                decisionText, scorePct, meanRevScore);
        } else if (meanRevScore != 0) {
            // Trade nonostante mean-reversion contrario (trend dominante)
            PrintFormat("[VOTE] %s APPROVATO | Score: %.1f%% (Mean-Rev: %+.3f contrario, trend domina)",
                decisionText, scorePct, meanRevScore);
        } else {
            // Trade normale senza mean-reversion significativo
            PrintFormat("[VOTE] %s APPROVATO | Score: %.1f%% >= %.1f%% soglia",
                decisionText, scorePct, currentThreshold);
        }
    }
    else if (g_enableLogsEffective) {
        // Nessun trade
        string reason = "";
        if (scorePct < effectiveThreshold) {
            if (g_lastHurstSoftActive) {
                reason = StringFormat("Score %.1f%% < %.1f%% soglia (HurstSoft x%.2f, base=%.1f%%)",
                    scorePct, effectiveThreshold, hurstSoftMult, currentThreshold);
            } else {
                reason = StringFormat("Score %.1f%% < %.1f%% soglia", scorePct, currentThreshold);
            }
        } else {
            reason = "Direzione neutra";
        }
        PrintFormat("[VOTE]  NO TRADE | %s", reason);
    }
    else {
        //  FIX: Log throttled anche in backtest per diagnostica blocchi
        static int noTradeCount = 0;
        noTradeCount++;
        if (noTradeCount == 1 || noTradeCount == 10 || noTradeCount == 50 || noTradeCount % 100 == 0) {
            string reason = (scorePct < currentThreshold) ? 
                StringFormat("Score %.1f%% < %.1f%% soglia", scorePct, currentThreshold) : "Direzione neutra";
            PrintFormat("[VOTE STATS #%d] NO TRADE: %s | TF attivi: M5=%d H1=%d H4=%d D1=%d", 
                noTradeCount, reason,
                g_vote_M5_active ? 1 : 0, g_vote_H1_active ? 1 : 0, 
                g_vote_H4_active ? 1 : 0, g_vote_D1_active ? 1 : 0);
        }
    }
    
    // v1.1: Salva score per Youden (collegare a profitto del trade)
    if (decision != 0) {
        g_lastEntryScore = scorePct;  // Sar collegato al profit quando il trade chiude
    }
    
    return decision;
}

//+------------------------------------------------------------------+
//| Apri ordine SELL                                                 |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
    if (SellLotSize <= 0) return;
    
    // VALIDAZIONE LOTTO: rispetta limiti broker
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    double finalLot = SellLotSize;
    
    // Clamp al range consentito
    if (finalLot < minLot) {
        PrintFormat("[TRADE] SELL Lotto %.2f < min %.2f - adeguato", finalLot, minLot);
        finalLot = minLot;
    }
    if (finalLot > maxLot) {
        PrintFormat("[TRADE] SELL Lotto %.2f > max %.2f - adeguato", finalLot, maxLot);
        finalLot = maxLot;
    }
    
    // Arrotonda allo step consentito
    if (stepLot > 0) {
        finalLot = MathFloor(finalLot / stepLot) * stepLot;
    }
    
    // NormalizeDouble per evitare errori di precisione
    finalLot = NormalizeDouble(finalLot, 2);
    
    if (finalLot < minLot) {
        Print("[TRADE] SELL Lotto nullo dopo normalizzazione - skip");
        return;
    }
    
    //  CATTURA DATI PRE-TRADE per analisi
    double askBefore = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bidBefore = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadBefore = (askBefore - bidBefore) / _Point;
    
    double price = bidBefore;
    double sl = 0;
    double tp = 0;

    // SL: priorita' a prezzo fisso, altrimenti punti
    if (StopLossPriceSell > 0)
        sl = StopLossPriceSell;
    else if (SellStopLossPoints > 0)
        sl = price + SellStopLossPoints * _Point;

    // TP: priorita' a prezzo fisso, altrimenti punti
    if (TakeProfitPriceSell > 0)
        tp = TakeProfitPriceSell;
    else if (SellTakeProfitPoints > 0)
        tp = price - SellTakeProfitPoints * _Point;
    
    if (trade.Sell(finalLot, _Symbol, price, sl, tp, "Auto SELL")) {
        // CALCOLA SLIPPAGE
        double executedPrice = trade.ResultPrice();
        double slippagePoints = (bidBefore - executedPrice) / _Point;
        
        //  v1.1 FIX: Registra score per questo trade (per Youden)
        // FIX CRITICO: ResultDeal() e' un DEAL ticket, non un POSITION_ID.
        // Per matching stabile in OnTradeTransaction usiamo DEAL_POSITION_ID.
        ulong dealTicket = trade.ResultDeal();
        ulong positionId = ResolvePositionIdFromDealTicket(dealTicket);
        if (positionId == 0) positionId = dealTicket;  // Fallback (coperto anche dal fallback in OnTradeTransaction)
        RegisterOpenTradeScore(positionId, g_lastEntryScore);

        // EXPORT ESTESO: snapshot entry (serve per CSV esteso e debug serio)
        EntrySnapshot snap;
        snap.positionId = positionId;
        snap.openTime = TimeCurrent();
        snap.direction = -1;
        snap.volume = finalLot;
        snap.requestedPrice = bidBefore;
        snap.executedPrice = executedPrice;
        snap.sl = sl;
        snap.tp = tp;
        snap.spreadPtsAtOpen = spreadBefore;
        snap.slippagePtsAtOpen = slippagePoints;

        snap.scorePctAtEntry = g_lastEntryScore;
        snap.thresholdBasePct = g_lastThresholdBasePct;
        snap.thresholdEffPct = g_lastThresholdEffPct;
        // Metodo soglia al momento dell'entry (serve per validare OTSU/YOUDEN offline)
        if (!AutoScoreThreshold) {
            snap.thresholdMethodId = 0;
        } else if (!g_scoreThresholdReady) {
            snap.thresholdMethodId = 1;
        } else {
            snap.thresholdMethodId = g_youdenReady ? 3 : 2;
        }
        snap.hurstSoftMult = g_lastHurstSoftMult;
        snap.tfCoherenceMult = g_lastTFCoherenceMult;
        snap.tfCoherenceConflicts = g_lastTFCoherenceConflictCount;
        snap.tfCoherenceSupports = g_lastTFCoherenceSupportCount;
        snap.tfCoherenceBlocked = g_lastTFCoherenceBlocked ? 1 : 0;

        snap.hurstTradeScore = g_hurstTradeScore;
        snap.hurstTradeThreshold = g_tradeScoreThreshold;
        snap.hurstReady = g_hurstReady ? 1 : 0;
        snap.hurstAllowTrade = g_hurstAllowTrade ? 1 : 0;
        snap.hurstGlobal = g_hurstGlobal;
        snap.hurstComposite = g_hurstComposite;
        snap.hurstCenter = g_hurstCenter;
        snap.hurstStdev = g_hurstStdev;
        snap.regimeM5 = RegimeToInt(g_hurstRegime_M5);
        snap.regimeH1 = RegimeToInt(g_hurstRegime_H1);
        snap.regimeH4 = RegimeToInt(g_hurstRegime_H4);
        snap.regimeD1 = RegimeToInt(g_hurstRegime_D1);

        RegisterEntrySnapshot(snap);
        
        // Aggiorna statistiche
        g_stats.totalSlippage += MathAbs(slippagePoints);
        g_stats.slippageCount++;
        
        // Aggiorna equity peak per drawdown
        double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        if (currentEquity > g_stats.peakEquity) {
            g_stats.peakEquity = currentEquity;
        }
        g_stats.lastTradeTime = TimeCurrent();
        
        //  LOG COMPLETO per analisi profitto
        PrintFormat("[TRADE] SELL APERTO #%I64u | Score@Entry=%.1f%%", positionId, g_lastEntryScore);
        PrintFormat("   Prezzo: richiesto=%.5f eseguito=%.5f | Slippage=%.1f pts",
            bidBefore, executedPrice, slippagePoints);
        PrintFormat("   Spread=%.1f pts | Lot=%.2f | SL=%.5f | TP=%.5f",
            spreadBefore, finalLot, sl, tp);
        if (sl > 0 || tp > 0) {
            double riskPips = sl > 0 ? (sl - price) / _Point / 10 : 0;
            double rewardPips = tp > 0 ? (price - tp) / _Point / 10 : 0;
            double rr = (riskPips > 0 && rewardPips > 0) ? rewardPips / riskPips : 0;
            PrintFormat("   Risk (SL): %.2f pips | Reward (TP): %.2f pips | R:R=1:%.2f",
                riskPips, rewardPips, rr);
        }

        if (EnableLogs && ExportExtendedTradesCSV) {
            PrintFormat("[SNAP] EntrySnapshot saved #%I64u | score=%.1f%% thr=%.1f%% eff=%.1f%% | Hsoft x%.2f | TFcoh x%.2f (c=%d s=%d) | Hts=%.4f/%.4f %s",
                positionId,
                snap.scorePctAtEntry, snap.thresholdBasePct, snap.thresholdEffPct,
                snap.hurstSoftMult,
                snap.tfCoherenceMult, snap.tfCoherenceConflicts, snap.tfCoherenceSupports,
                snap.hurstTradeScore, snap.hurstTradeThreshold,
                snap.hurstReady ? (snap.hurstAllowTrade ? "OK" : "BLOCK") : "NR");
        }
    } else {
        int errCode = GetLastError();
        PrintFormat("[TRADE] SELL FALLITO! Errore %d: %s | Price=%.5f Lot=%.2f SL=%.5f TP=%.5f",
            errCode, ErrorDescription(errCode), price, finalLot, sl, tp);

        // Circuit Breaker: errore operativo (OrderSend fallito)
        CB_RecordOperationalError("SELL_ORDER_FAIL", errCode);
    }
}

//+------------------------------------------------------------------+
//| Apri ordine BUY                                                  |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
    if (BuyLotSize <= 0) return;
    
    // VALIDAZIONE LOTTO: rispetta limiti broker
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    double finalLot = BuyLotSize;
    
    // Clamp al range consentito
    if (finalLot < minLot) {
        PrintFormat("[TRADE] BUY Lotto %.2f < min %.2f - adeguato", finalLot, minLot);
        finalLot = minLot;
    }
    if (finalLot > maxLot) {
        PrintFormat("[TRADE] BUY Lotto %.2f > max %.2f - adeguato", finalLot, maxLot);
        finalLot = maxLot;
    }
    
    // Arrotonda allo step consentito
    if (stepLot > 0) {
        finalLot = MathFloor(finalLot / stepLot) * stepLot;
    }
    
    // NormalizeDouble per evitare errori di precisione
    finalLot = NormalizeDouble(finalLot, 2);
    
    if (finalLot < minLot) {
        Print("[TRADE] BUY Lotto nullo dopo normalizzazione - skip");
        return;
    }
    
    // CATTURA DATI PRE-TRADE per analisi
    double askBefore = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bidBefore = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadBefore = (askBefore - bidBefore) / _Point;
    
    double price = askBefore;
    double sl = 0;
    double tp = 0;

    // SL: priorita' a prezzo fisso, altrimenti punti
    if (StopLossPriceBuy > 0)
        sl = StopLossPriceBuy;
    else if (BuyStopLossPoints > 0)
        sl = price - BuyStopLossPoints * _Point;

    // TP: priorita' a prezzo fisso, altrimenti punti
    if (TakeProfitPriceBuy > 0)
        tp = TakeProfitPriceBuy;
    else if (BuyTakeProfitPoints > 0)
        tp = price + BuyTakeProfitPoints * _Point;
    
    if (trade.Buy(finalLot, _Symbol, price, sl, tp, "Auto BUY")) {
        // CALCOLA SLIPPAGE
        double executedPrice = trade.ResultPrice();
        double slippagePoints = (executedPrice - askBefore) / _Point;
        
        //  v1.1 FIX: Registra score per questo trade (per Youden)
        // FIX CRITICO: ResultDeal() e' un DEAL ticket, non un POSITION_ID.
        // Per matching stabile in OnTradeTransaction usiamo DEAL_POSITION_ID.
        ulong dealTicket = trade.ResultDeal();
        ulong positionId = ResolvePositionIdFromDealTicket(dealTicket);
        if (positionId == 0) positionId = dealTicket;  // Fallback
        RegisterOpenTradeScore(positionId, g_lastEntryScore);

        // EXPORT ESTESO: snapshot entry
        EntrySnapshot snap;
        snap.positionId = positionId;
        snap.openTime = TimeCurrent();
        snap.direction = 1;
        snap.volume = finalLot;
        snap.requestedPrice = askBefore;
        snap.executedPrice = executedPrice;
        snap.sl = sl;
        snap.tp = tp;
        snap.spreadPtsAtOpen = spreadBefore;
        snap.slippagePtsAtOpen = slippagePoints;

        snap.scorePctAtEntry = g_lastEntryScore;
        snap.thresholdBasePct = g_lastThresholdBasePct;
        snap.thresholdEffPct = g_lastThresholdEffPct;
        if (!AutoScoreThreshold) {
            snap.thresholdMethodId = 0;
        } else if (!g_scoreThresholdReady) {
            snap.thresholdMethodId = 1;
        } else {
            snap.thresholdMethodId = g_youdenReady ? 3 : 2;
        }
        snap.hurstSoftMult = g_lastHurstSoftMult;
        snap.tfCoherenceMult = g_lastTFCoherenceMult;
        snap.tfCoherenceConflicts = g_lastTFCoherenceConflictCount;
        snap.tfCoherenceSupports = g_lastTFCoherenceSupportCount;
        snap.tfCoherenceBlocked = g_lastTFCoherenceBlocked ? 1 : 0;

        snap.hurstTradeScore = g_hurstTradeScore;
        snap.hurstTradeThreshold = g_tradeScoreThreshold;
        snap.hurstReady = g_hurstReady ? 1 : 0;
        snap.hurstAllowTrade = g_hurstAllowTrade ? 1 : 0;
        snap.hurstGlobal = g_hurstGlobal;
        snap.hurstComposite = g_hurstComposite;
        snap.hurstCenter = g_hurstCenter;
        snap.hurstStdev = g_hurstStdev;
        snap.regimeM5 = RegimeToInt(g_hurstRegime_M5);
        snap.regimeH1 = RegimeToInt(g_hurstRegime_H1);
        snap.regimeH4 = RegimeToInt(g_hurstRegime_H4);
        snap.regimeD1 = RegimeToInt(g_hurstRegime_D1);

        RegisterEntrySnapshot(snap);
        
        // Aggiorna statistiche
        g_stats.totalSlippage += MathAbs(slippagePoints);
        g_stats.slippageCount++;
        
        // Aggiorna equity peak per drawdown
        double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        if (currentEquity > g_stats.peakEquity) {
            g_stats.peakEquity = currentEquity;
        }
        g_stats.lastTradeTime = TimeCurrent();
        
        //  LOG COMPLETO per analisi profitto
        PrintFormat("[TRADE] BUY APERTO #%I64u | Score@Entry=%.1f%%", positionId, g_lastEntryScore);
        PrintFormat("   Prezzo: richiesto=%.5f eseguito=%.5f | Slippage=%.1f pts",
            askBefore, executedPrice, slippagePoints);
        PrintFormat("   Spread=%.1f pts | Lot=%.2f | SL=%.5f | TP=%.5f",
            spreadBefore, finalLot, sl, tp);
        if (sl > 0 || tp > 0) {
            double riskPips = sl > 0 ? (price - sl) / _Point / 10 : 0;
            double rewardPips = tp > 0 ? (tp - price) / _Point / 10 : 0;
            double rr = (riskPips > 0 && rewardPips > 0) ? rewardPips / riskPips : 0;
            PrintFormat("   Risk (SL): %.2f pips | Reward (TP): %.2f pips | R:R=1:%.2f",
                riskPips, rewardPips, rr);
        }

        if (EnableLogs && ExportExtendedTradesCSV) {
            PrintFormat("[SNAP] EntrySnapshot saved #%I64u | score=%.1f%% thr=%.1f%% eff=%.1f%% | Hsoft x%.2f | TFcoh x%.2f (c=%d s=%d) | Hts=%.4f/%.4f %s",
                positionId,
                snap.scorePctAtEntry, snap.thresholdBasePct, snap.thresholdEffPct,
                snap.hurstSoftMult,
                snap.tfCoherenceMult, snap.tfCoherenceConflicts, snap.tfCoherenceSupports,
                snap.hurstTradeScore, snap.hurstTradeThreshold,
                snap.hurstReady ? (snap.hurstAllowTrade ? "OK" : "BLOCK") : "NR");
        }
    } else {
        int errCode = GetLastError();
        PrintFormat("[TRADE] BUY FALLITO! Errore %d: %s | Price=%.5f Lot=%.2f SL=%.5f TP=%.5f Spread=%.1f",
            errCode, ErrorDescription(errCode), price, finalLot, sl, tp, spreadBefore);

        // Circuit Breaker: errore operativo (OrderSend fallito)
        CB_RecordOperationalError("BUY_ORDER_FAIL", errCode);
    }
}

//+------------------------------------------------------------------+
//|  TRAILING STOP: Aggiorna SL per proteggere profitti           |
//| Logica: Dopo X punti profitto, mantieni SL a Y punti dal prezzo |
//+------------------------------------------------------------------+
void UpdateTrailingStops()
{
    // Check se almeno uno dei trailing  attivo
    if (BuyTrailingStartPoints <= 0 && SellTrailingStartPoints <= 0) return;
    
    int totalPositions = PositionsTotal();
    if (totalPositions == 0) return;
    
    // Usiamo POINTS (Symbol point size). 1 point = SYMBOL_POINT.
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    int uniqueMagic = g_uniqueMagicNumber;
    
    for (int i = 0; i < totalPositions; i++) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != uniqueMagic) continue;
        
        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentTP = PositionGetDouble(POSITION_TP);
        double volume = PositionGetDouble(POSITION_VOLUME);
        
        // Determina parametri trailing (in POINTS) per questo tipo
        int trailingStart = (type == POSITION_TYPE_BUY) ? BuyTrailingStartPoints : SellTrailingStartPoints;
        int trailingStep  = (type == POSITION_TYPE_BUY) ? BuyTrailingStepPoints  : SellTrailingStepPoints;
        
        if (trailingStart <= 0) continue; // Trailing disabilitato per questo tipo
        
        double currentPrice = (type == POSITION_TYPE_BUY) ? 
            SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
            SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        
        // Calcola profitto in POINTS
        double profitPoints = 0;
        if (type == POSITION_TYPE_BUY) {
            profitPoints = (currentPrice - openPrice) / point;
        } else {
            profitPoints = (openPrice - currentPrice) / point;
        }
        
        // Verifica se profitto sufficiente per attivare trailing
        if (profitPoints < trailingStart) continue;
        
        // Calcola nuovo SL basato su trailing step
        double newSL = 0;
        if (type == POSITION_TYPE_BUY) {
            // BUY: SL = Bid - trailingStep POINTS
            newSL = currentPrice - (trailingStep * point);
            newSL = NormalizeDouble(newSL, digits);
            
            // Aggiorna solo se nuovo SL  migliore (pi alto)
            if (currentSL > 0 && newSL <= currentSL) continue;
            if (newSL <= openPrice) continue; // Non mettere SL sotto breakeven
        } else {
            // SELL: SL = Ask + trailingStep POINTS
            newSL = currentPrice + (trailingStep * point);
            newSL = NormalizeDouble(newSL, digits);
            
            // Aggiorna solo se nuovo SL  migliore (pi basso)
            if (currentSL > 0 && newSL >= currentSL) continue;
            if (newSL >= openPrice) continue; // Non mettere SL sopra breakeven
        }
        
        // Modifica posizione con nuovo SL
        if (trade.PositionModify(ticket, newSL, currentTP)) {
            PrintFormat("[TRAILING] Aggiornato SL posizione #%I64u %s | Profit: %.0f points | Nuovo SL: %.5f (step %d points)",
                ticket, type == POSITION_TYPE_BUY ? "BUY" : "SELL", 
                profitPoints, newSL, trailingStep);
        } else {
            int errCode = GetLastError();
            // Log errore solo se non  "no changes" (codice 10025)
            if (errCode != 10025) {
                PrintFormat("[TRAILING] WARN: errore modifica SL #%I64u: %d - %s",
                    ticket, errCode, ErrorDescription(errCode));
            }
        }
    }
}

//+------------------------------------------------------------------+
//|  EXIT ANTICIPATO: Chiude posizioni in perdita su segnale contrario forte |
//| Usa mean-reversion e cambio regime per identificare inversioni   |
//+------------------------------------------------------------------+
void CheckEarlyExitOnReversal()
{
    int totalPositions = PositionsTotal();
    if (totalPositions == 0) return;
    
    int uniqueMagic = g_uniqueMagicNumber;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    // Ottieni segnali mean-reversion correnti
    double reversalStrength = 0.0;
    int reversalSignal = GetReversalSignal(reversalStrength, false);
    
    // Exit solo se segnale reversal FORTE (sopra soglia data-driven)
    if (reversalSignal == 0 || reversalStrength < g_reversalThreshold) return;
    
    for (int i = totalPositions - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != uniqueMagic) continue;
        
        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double profitPL = PositionGetDouble(POSITION_PROFIT);
        
        // Chiudi solo posizioni in PERDITA
        if (profitPL >= 0) continue;
        
        double currentPrice = (type == POSITION_TYPE_BUY) ? 
            SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
            SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        
        // Calcola perdita in pips
        double lossPips = 0;
        if (type == POSITION_TYPE_BUY) {
            lossPips = (openPrice - currentPrice) / point / 10;
        } else {
            lossPips = (currentPrice - openPrice) / point / 10;
        }
        
        // Verifica se segnale reversal  CONTRARIO alla posizione
        bool shouldClose = false;
        string closeReason = "";
        
        if (type == POSITION_TYPE_BUY && reversalSignal < 0) {
            // BUY in perdita + segnale SELL reversal forte = CHIUDI
            shouldClose = true;
            closeReason = "Reversal BEARISH forte";
        } else if (type == POSITION_TYPE_SELL && reversalSignal > 0) {
            // SELL in perdita + segnale BUY reversal forte = CHIUDI
            shouldClose = true;
            closeReason = "Reversal BULLISH forte";
        }
        
        // Chiudi solo se perdita significativa (> decay(H)  ATR in pips)
        // Evita chiusure su noise normale
        double minLossThreshold = GetOrganicDecayPow(g_hurstGlobal, 2.0) * 20; // ~5-10 pips per H=0.5
        if (shouldClose && lossPips > minLossThreshold) {
            if (trade.PositionClose(ticket)) {
                PrintFormat("[EARLY EXIT] Chiusa posizione #%I64u %s | Loss: %.1f pips (%.2f EUR) | Motivo: %s (forza %.0f%%)",
                    ticket, type == POSITION_TYPE_BUY ? "BUY" : "SELL",
                    lossPips, profitPL, closeReason, reversalStrength * 100);
            } else {
                PrintFormat("[EARLY EXIT] WARN: errore chiusura #%I64u: %d", ticket, GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Stop loss temporale su posizioni aperte                          |
//|  FIX: Esclude weekend dal conteggio tempo                       |
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
    // FIX: Usa Magic cachato invece di ricalcolarlo ogni volta
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
        
        // FIX: Calcola tempo di TRADING effettivo (escludi weekend)
        // Mercato forex: chiude venerdi' ~22:00 UTC, apre domenica ~22:00 UTC
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
            // Venerdi': ultime ~2 ore non trading (mercato chiude ~22:00 UTC)
            // Approssimazione conservativa: non contiamo per evitare complessita'
            checkTime += 86400;  // Avanza di un giorno
        }
        
        // Sottrai tempo weekend
        int tradingSeconds = (int)MathMax(0, totalSeconds - weekendSeconds);
        int maxLifetimeSeconds = limitMinutes * 60;
        if (tradingSeconds < maxLifetimeSeconds) continue;
        
        int lifetimeMinutes = tradingSeconds / 60;
        
        double volume = PositionGetDouble(POSITION_VOLUME);
        double posProfit = PositionGetDouble(POSITION_PROFIT);
        // FIX: Rimossa dichiarazione duplicata di lifetimeMinutes (usava lifetimeSeconds inesistente)
        
        PrintFormat("[TIME STOP] Posizione #%I64u %s aperta da %d min (limite %d) - chiusura forzata", 
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
            PrintFormat("[TIME STOP] Errore chiusura posizione #%I64u: %d", ticket, GetLastError());
        }
    }
    
    if (closedCount > 0) {
        PrintFormat("[TIME STOP] Posizioni chiuse per durata massima: %d", closedCount);
    }
}

//+------------------------------------------------------------------+
//| Descrizione errore trading (funzione helper)                 |
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
//|  TRACCIA CHIUSURA TRADE E AGGIORNA STATISTICHE                 |
//| Chiamata automaticamente da MT5 per catturare ogni chiusura       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    // Ci interessa solo la chiusura di posizioni (DEAL)
    if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    
    // Verifica che sia una chiusura (DEAL_ENTRY_OUT / INOUT)
    if (!HistoryDealSelect(trans.deal)) return;
    
    ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
    if (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;
    
    // Verifica Magic Number
    long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
    if (dealMagic != g_uniqueMagicNumber) return;
    
    // Verifica simbolo
    string dealSymbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
    if (dealSymbol != _Symbol) return;
    
    // ---------------------------------------------------------------
    //  ESTRAI DATI DEL TRADE CHIUSO
    // ---------------------------------------------------------------
    double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
    double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
    double swap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
    double volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
    double closePrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
    ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
    ulong positionId = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
    if (positionId == 0) return;
    
    // Profitto netto (inclusi commission e swap)
    double netProfit = profit + commission + swap;
    
    // Aggiorna totali commission/swap
    g_stats.totalCommission += commission;
    g_stats.totalSwap += swap;
    
    // ---------------------------------------------------------------
    //  TROVA IL DEAL DI APERTURA per calcolare durata e prezzo entry
    // ---------------------------------------------------------------
    double openPrice = 0;
    datetime openTime = 0;
    datetime closeTime = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);

    // Circuit Breaker: aggiorna performance window/streak su trade chiuso
    CB_RecordClosedTrade(netProfit, closeTime);
    
    // Cerca nella history il deal di apertura con stesso position ID
    ulong openDealTicketFound = 0;
    HistorySelectByPosition(positionId);
    int totalDeals = HistoryDealsTotal();
    for (int i = 0; i < totalDeals; i++) {
        ulong dealTicket = HistoryDealGetTicket(i);
        if (dealTicket == 0) continue;
        
        ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
        if (dealEntry == DEAL_ENTRY_IN) {
            openPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            openTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
            openDealTicketFound = dealTicket;
            break;
        }
    }

    // ---------------------------------------------------------------
    // EXPORT ESTESO: usa snapshot entry (se disponibile)
    // ---------------------------------------------------------------
    EntrySnapshot snap;
    ZeroMemory(snap);
    bool snapFound = false;

    // Se la posizione è ancora aperta (chiusura parziale), NON rimuovere lo snapshot.
    // Nota MT5: DEAL_POSITION_ID corrisponde a POSITION_IDENTIFIER (NON al ticket).
    bool positionStillOpen = IsPositionOpenById(positionId);

    // Alcuni ambienti popolano trans.position con il ticket della posizione: prova a risolvere l'identifier.
    ulong altPositionId = 0;
    if (trans.position != 0) {
        if (PositionSelectByTicket((ulong)trans.position)) {
            long ident = PositionGetInteger(POSITION_IDENTIFIER);
            if (ident > 0) altPositionId = (ulong)ident;
        }
    }

    if (positionStillOpen) {
        snapFound = GetEntrySnapshot(positionId, snap);
        if (!snapFound && altPositionId != 0 && altPositionId != positionId) {
            snapFound = GetEntrySnapshot(altPositionId, snap);
        }
    } else {
        snapFound = GetAndRemoveEntrySnapshot(positionId, snap);
        if (!snapFound && altPositionId != 0 && altPositionId != positionId) {
            snapFound = GetAndRemoveEntrySnapshot(altPositionId, snap);
        }
    }

    if (snapFound) {
        if (snap.openTime > 0) openTime = snap.openTime;
        if (snap.executedPrice > 0) openPrice = snap.executedPrice;
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

    // Score@Entry (snapshot preferito). Importante: su chiusure parziali NON consumare la mappa ticket->score.
    double scoreAtEntry = 0.0;
    if (snapFound && snap.scorePctAtEntry > 0.0) {
        scoreAtEntry = snap.scorePctAtEntry;
    } else {
        if (positionStillOpen) {
            double tmp = 0.0;
            if (GetTradeScore(positionId, tmp)) {
                scoreAtEntry = tmp;
            }
        } else {
            scoreAtEntry = GetAndRemoveTradeScore(positionId);
            if (scoreAtEntry <= 0.0 && openDealTicketFound != 0) {
                scoreAtEntry = GetAndRemoveTradeScore(openDealTicketFound);
            }
        }
    }

    // ---------------------------------------------------------------
    //  SALVA RECORD ESTESO (persistente per export)
    // ---------------------------------------------------------------
    if (ExportExtendedTradesCSV) {
        ExtendedTradeRecord rec;
        rec.positionId = positionId;
        rec.openTime = openTime;
        rec.closeTime = closeTime;
        // Direzione: priorita' allo snapshot (entry reale), altrimenti inferenza dalla chiusura
        if (snapFound && (snap.direction == 1 || snap.direction == -1)) {
            rec.direction = snap.direction;
        } else {
            // Fallback: SELL close tende a chiudere BUY; BUY close tende a chiudere SELL
            rec.direction = (dealType == DEAL_TYPE_SELL) ? 1 : -1;
        }
        rec.symbol = _Symbol;
        rec.volume = volume;
        rec.requestedOpenPrice = snapFound ? snap.requestedPrice : openPrice;
        rec.executedOpenPrice = snapFound ? snap.executedPrice : openPrice;
        rec.openPrice = rec.executedOpenPrice;
        rec.closePrice = closePrice;
        rec.commission = commission;
        rec.swap = swap;
        rec.profit = profit;
        rec.netProfit = netProfit;
        rec.balanceAfter = AccountInfoDouble(ACCOUNT_BALANCE);
        rec.durationMinutes = durationMinutes;
        rec.magic = dealMagic;
        rec.comment = comment;
        rec.closeReason = closeReason;

        rec.spreadPtsAtOpen = snapFound ? snap.spreadPtsAtOpen : 0.0;
        rec.slippagePtsAtOpen = snapFound ? snap.slippagePtsAtOpen : 0.0;
        rec.sl = snapFound ? snap.sl : 0.0;
        rec.tp = snapFound ? snap.tp : 0.0;

        rec.scorePctAtEntry = scoreAtEntry;
        rec.thresholdBasePct = snapFound ? snap.thresholdBasePct : 0.0;
        rec.thresholdEffPct = snapFound ? snap.thresholdEffPct : 0.0;
        if (snapFound) {
            rec.thresholdMethodId = snap.thresholdMethodId;
        } else {
            // Fallback (meno affidabile): stato corrente al momento della chiusura
            if (!AutoScoreThreshold) rec.thresholdMethodId = 0;
            else if (!g_scoreThresholdReady) rec.thresholdMethodId = 1;
            else rec.thresholdMethodId = g_youdenReady ? 3 : 2;
        }
        rec.hurstSoftMult = snapFound ? snap.hurstSoftMult : 0.0;
        rec.tfCoherenceMult = snapFound ? snap.tfCoherenceMult : 0.0;
        rec.tfCoherenceConflicts = snapFound ? snap.tfCoherenceConflicts : 0;
        rec.tfCoherenceSupports = snapFound ? snap.tfCoherenceSupports : 0;
        rec.tfCoherenceBlocked = snapFound ? snap.tfCoherenceBlocked : 0;

        rec.hurstTradeScore = snapFound ? snap.hurstTradeScore : 0.0;
        rec.hurstTradeThreshold = snapFound ? snap.hurstTradeThreshold : 0.0;
        rec.hurstReady = snapFound ? snap.hurstReady : 0;
        rec.hurstAllowTrade = snapFound ? snap.hurstAllowTrade : 0;
        rec.hurstGlobal = snapFound ? snap.hurstGlobal : 0.0;
        rec.hurstComposite = snapFound ? snap.hurstComposite : 0.0;
        rec.hurstCenter = snapFound ? snap.hurstCenter : 0.0;
        rec.hurstStdev = snapFound ? snap.hurstStdev : 0.0;
        rec.regimeM5 = snapFound ? snap.regimeM5 : 0;
        rec.regimeH1 = snapFound ? snap.regimeH1 : 0;
        rec.regimeH4 = snapFound ? snap.regimeH4 : 0;
        rec.regimeD1 = snapFound ? snap.regimeD1 : 0;

        AppendExtendedTrade(rec);

        if (EnableLogs) {
            PrintFormat("[EXT] Trade close captured #%I64u | net=%+.2f | snap=%s | partial=%s | reason=%s",
                positionId, netProfit,
                snapFound ? "YES" : "NO",
                positionStillOpen ? "YES" : "NO",
                closeReason);
        }
    }
    
    // ---------------------------------------------------------------
    //  AGGIORNA STATISTICHE
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
    //  LOG COMPLETO CHIUSURA TRADE
    // ---------------------------------------------------------------
    string profitIcon = (netProfit >= 0) ? "WIN" : "LOSS";
    string typeStr = (dealType == DEAL_TYPE_BUY) ? "SELL_CLOSE" : "BUY_CLOSE";
    
    Print("+--------------------------------------------------------------+");
    PrintFormat("%s TRADE CHIUSO #%I64u (%s) @ %s", profitIcon, positionId, closeReason,
        TimeToString(closeTime, TIME_DATE|TIME_MINUTES));
    Print("--------------------------------------------------------------");
    PrintFormat("Tipo: %s | Volume: %.2f lot | Durata: %d min (%.1fh)", 
        typeStr, volume, durationMinutes, durationMinutes / 60.0);
    PrintFormat("Entry: %.5f @ %s", openPrice, TimeToString(openTime, TIME_DATE|TIME_MINUTES));
    PrintFormat("Exit:  %.5f @ %s", closePrice, TimeToString(closeTime, TIME_DATE|TIME_MINUTES));
    
    // Pips e R:R
    double pips = 0;
    if (openPrice > 0) {
        if (dealType == DEAL_TYPE_BUY) {
            pips = (closePrice - openPrice) / _Point / 10;  // SELL close = BUY open
        } else {
            pips = (openPrice - closePrice) / _Point / 10;  // BUY close = SELL open
        }
    }
    PrintFormat("Pips: %+.1f | Profit: %.2f | Comm: %.2f | Swap: %.2f", 
        pips, profit, commission, swap);
    PrintFormat("NET P/L: %+.2f %s (%.2f%% of %.2f equity)", 
        netProfit, AccountInfoString(ACCOUNT_CURRENCY),
        currentEquity > 0 ? (netProfit / currentEquity * 100) : 0, currentEquity);
    
    // Score breakdown e regime
    if (scoreAtEntry > 0) {
        double thresholdAtEntry = g_scoreThresholdReady ? g_dynamicThreshold : ScoreThreshold;
        PrintFormat("Score@Entry: %.1f%% (soglia %.1f%%) | Regime H=%.3f (%s)",
            scoreAtEntry, thresholdAtEntry, g_hurstGlobal,
            g_hurstGlobal > (g_hurstZoneReady ? g_hurstRandomHigh : 0.55) ? "TREND" :
            g_hurstGlobal < (g_hurstZoneReady ? g_hurstRandomLow : 0.45) ? "REVERT" : "RANDOM");
    }
    
    Print("--------------------------------------------------------------");
    PrintFormat("STATISTICHE CUMULATIVE (dopo %d trade)", g_stats.totalTrades);
    PrintFormat("W:%d L:%d = %.1f%% WinRate | Streak: %+d (MaxW:%d MaxL:%d)", 
        g_stats.winTrades, g_stats.lossTrades,
        g_stats.totalTrades > 0 ? (100.0 * g_stats.winTrades / g_stats.totalTrades) : 0,
        (int)g_stats.currentStreak, g_stats.maxWinStreak, g_stats.maxLossStreak);
    PrintFormat("PF: %.2f | Expect: %+.2f | AvgW: %.2f | AvgL: %.2f", 
        g_stats.profitFactor, g_stats.expectancy, g_stats.avgWin, g_stats.avgLoss);
    PrintFormat("MaxDD: %.2f (%.2f%%) | CurrentDD: %.2f (%.2f%%)",
        g_stats.maxDrawdown, g_stats.maxDrawdownPct, currentDD, currentDDPct);
    PrintFormat("Total: Profit=%.2f Loss=%.2f Net=%+.2f | Comm=%.2f Swap=%.2f",
        g_stats.totalProfit, g_stats.totalLoss, g_stats.totalProfit - g_stats.totalLoss,
        g_stats.totalCommission, g_stats.totalSwap);
    Print("+--------------------------------------------------------------+");
    
    // ---------------------------------------------------------------
    //  SALVA NEL BUFFER TRADE RECENTI (per analisi pattern e Youden)
    // ---------------------------------------------------------------
    //  SAFETY: Usa ArraySize() per dimensione reale
    int tradesMax = ArraySize(g_recentTrades);
    if (tradesMax > 0) {
        g_recentTrades[g_recentTradesIndex].ticket = positionId;
        g_recentTrades[g_recentTradesIndex].openTime = openTime;
        g_recentTrades[g_recentTradesIndex].closeTime = closeTime;
        g_recentTrades[g_recentTradesIndex].type = (dealType == DEAL_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
        g_recentTrades[g_recentTradesIndex].openPrice = openPrice;
        g_recentTrades[g_recentTradesIndex].closePrice = closePrice;
        g_recentTrades[g_recentTradesIndex].volume = volume;
        g_recentTrades[g_recentTradesIndex].profit = netProfit;
        g_recentTrades[g_recentTradesIndex].closeReason = closeReason;
        
        //  v1.1 FIX: Recupera score CORRETTO dalla mappa ticket  score
        // Prima usavamo g_lastEntryScore che veniva sovrascritto tra apertura e chiusura
        // NOTA: scoreAtEntry gi recuperato e loggato nel blocco sopra
        g_recentTrades[g_recentTradesIndex].scoreAtEntry = scoreAtEntry;
        
        // Log per debug Youden con contesto completo
        if (g_enableLogsEffective && scoreAtEntry > 0) {
            PrintFormat("[YOUDEN] Trade #%d: Score=%.1f%% -> P/L=%+.2f (%s) | PF=%.2f WR=%.1f%%",
                g_recentTradesCount, scoreAtEntry, netProfit, netProfit >= 0 ? "WIN" : "LOSS",
                g_stats.profitFactor, 
                g_stats.totalTrades > 0 ? (100.0 * g_stats.winTrades / g_stats.totalTrades) : 0);
        }
        
        g_recentTradesIndex = (g_recentTradesIndex + 1) % tradesMax;
        if (g_recentTradesCount < g_recentTradesMax) g_recentTradesCount++;
        
        //  SUMMARY PERIODICO ogni 10 trade
        if (g_stats.totalTrades % 10 == 0 && g_enableLogsEffective) {
            Print("");
            Print("============================================================");
            PrintFormat("PERFORMANCE SUMMARY @ %s (Trade #%d)",
                TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES), g_stats.totalTrades);
            PrintFormat("WinRate: %.1f%% (%d/%d) | PF: %.2f | Expect: %+.2f",
                g_stats.totalTrades > 0 ? (100.0 * g_stats.winTrades / g_stats.totalTrades) : 0,
                g_stats.winTrades, g_stats.totalTrades, g_stats.profitFactor, g_stats.expectancy);
            PrintFormat("AvgWin: %.2f | AvgLoss: %.2f | Max Streak: W:%d L:%d",
                g_stats.avgWin, g_stats.avgLoss, g_stats.maxWinStreak, g_stats.maxLossStreak);
            PrintFormat("MaxDD: %.2f (%.2f%%) | Peak Equity: %.2f",
                g_stats.maxDrawdown, g_stats.maxDrawdownPct, g_stats.peakEquity);
            PrintFormat("Net P/L: %+.2f | Comm: %.2f | Swap: %.2f",
                g_stats.totalProfit - g_stats.totalLoss, g_stats.totalCommission, g_stats.totalSwap);
            
            // Threshold e regime info
            PrintFormat("Threshold: %.1f%% (%s) | H: %.3f (%s) | TF: M5=%s H1=%s H4=%s D1=%s",
                g_scoreThresholdReady ? g_dynamicThreshold : ScoreThreshold,
                AutoScoreThreshold ? (g_youdenReady ? "Youden" : "Otsu") : "Manual",
                g_hurstGlobal,
                g_hurstGlobal > (g_hurstZoneReady ? g_hurstRandomHigh : 0.55) ? "TREND" :
                g_hurstGlobal < (g_hurstZoneReady ? g_hurstRandomLow : 0.45) ? "REVERT" : "RANDOM",
                g_vote_M5_active ? "ON" : "OFF",
                g_vote_H1_active ? "ON" : "OFF",
                g_vote_H4_active ? "ON" : "OFF",
                g_vote_D1_active ? "ON" : "OFF");
            Print("============================================================");
            Print("");
        }
    }
}
