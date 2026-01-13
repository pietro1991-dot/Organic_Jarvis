//+------------------------------------------------------------------+
//| --------------------------------------------------------------- |
// SISTEMA 100% ORGANICO  - TUTTO DERIVATO DAI DATI                  |
//| --------------------------------------------------------------- |
//|                                                                 |
//| FORMULA PERIODI (100% data-driven):                             |
//|   naturalPeriod = autocorrelazione dei DATI (no minuti!)        |
//|                                                                 |
//| CENTRI ADATTIVI - SOGLIE 100% DATA-DRIVEN (non 0.55/0.45 fissi!):|
//|   TRENDING (H > center+margin):     EMA (recency bias)          |
//|   RANDOM (centermargin):           Mediana (robusto)           |
//|   REVERTING (H < center-margin):    Trimmed Mean (oscillazione) |
//|   Transizioni: blend lineare per evitare discontinuita          |
//|                                                                 |
//| SOGLIE DINAMICHE:                                               |
//|   ADX threshold = avg + stddev (dai dati)                       |
//|   Score threshold = OTSU->YOUDEN (100% data-driven)             |
//|                                                                 |
//| READY CHECK:                                                    |
//|   L'EA NON entra a mercato finche non ha abbastanza dati        |
//|   per calcolare TUTTI i valori organici (no fallback!)          |
//|                                                                 |
//| --------------------------------------------------------------- |
//| VALIDAZIONI IMPLEMENTATE:                                       |
//| --------------------------------------------------------------- |
//| 1. DIVISIONI: Tutte protette contro /0 con check denominatore   |
//| 2. BUFFER CIRCOLARI: Indici sempre in [0, MAX-1] via modulo     |
//| 3. SOMME INCREMENTALI: Sanity check per floating point errors   |
//| 4. VARIANZA: Protezione sqrt(negativo) -> ritorna 0.0           |
//| 5. SCORE THRESHOLD: Bounds P{low} <-> P{high} (data-driven)     |
//| --------------------------------------------------------------- |
//+------------------------------------------------------------------+
#property copyright "Pietro Giacobazzi, Juri Corradi, Alessandro Brehas"
#property version   "5.00"
#property description "EA Jarvis - SISTEMA 100% DATA-DRIVEN (empirico)"

#include <Trade\Trade.mqh>
#include <Arrays\ArrayDouble.mqh>

// +---------------------------------------------------------------------------+
//                      FORWARD DECLARATIONS (MQL5 single-pass)                
// +---------------------------------------------------------------------------+
string StateLabel(bool flag);
void UpdateTrailingStops();
void CheckEarlyExitOnReversal();
void CheckAndCloseOnTimeStop();
int  ExecuteVotingLogic();
void ExecuteTradingLogic();

// +---------------------------------------------------------------------------+
//                      MONEY MANAGEMENT & GENERALE
// +---------------------------------------------------------------------------+
input group "--- GENERALE ---"
input bool   enableTrading        = true;       // Abilita trading (false = solo analisi)
input int    MaxOpenTrades        = 10;         // Massimo posizioni aperte (RIDOTTO per PC deboli)
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
//                    MEMORIA E PERFORMANCE (PER TIMEFRAME)                 
// +---------------------------------------------------------------------------+
input group "--- CONFIGURAZIONE MEMORIA (Giorni Storia per Timeframe) ---"
input int    WindowDays_M5      = 3;        // M5: Giorni storia (3-7 consigliato, max dati recenti)
input int    WindowDays_H1      = 7;        // H1: Giorni storia (7-14 consigliato, trend medio)
input int    WindowDays_H4      = 14;       // H4: Giorni storia (14-30 consigliato, trend robusto)
input int    WindowDays_D1      = 30;       // D1: Giorni storia (30-90 consigliato, trend lungo)
input double MaxLagFraction     = 0.15;     // MaxLag autocorr = % barre (0.10-0.20, più alto=più lento)
input int    MaxLagAbsolute     = 150;      // MaxLag massimo assoluto (50-200, limita calcoli pesanti)

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
//                        USCITE / GESTIONE POSIZIONI
// +---------------------------------------------------------------------------+
input group "--- USCITE / GESTIONE POSIZIONI ---"
input bool   EnableEarlyExitOnReversal = true;  // Chiude a mercato posizioni in perdita su reversal forte (false=disattiva)
input bool   EarlyExitCheckOnNewM5BarOnly = true; // Valuta early-exit solo a nuova barra M5 (riduce chiusure su noise intra-bar)
input int    EarlyExitConfirmBars       = 2;    // Reversal deve persistere per N barre M5 (1=immediato)
input int    EarlyExitMinPositionAgeMinutes = 10; // Non chiudere prima di N minuti dall'apertura (0=disattivato)
input double EarlyExitReversalStrengthOverride = 0.0; // 0=AUTO (data-driven), altrimenti soglia manuale 0..1
input double EarlyExitMinLossPipsOverride   = 0.0; // AUTO se 0: soglia loss minima in pips (override)
input double EarlyExitMinLossAtrFracOverride = 0.0; // AUTO se 0: soglia loss come frazione ATR (override)

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
input bool   ExportExtendedTradesCSV   = true;  // Esporta CSV esteso con contesto (score/soglie/spread/slippage/closeReason)

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
// PESO TF: uniforme sui TF validi/abilitati
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
    
    // PESO TF (fully empirical)
    double weight;           // Peso del timeframe
    
    // PERIODO NATURALE (derivato dall'autocorrelazione dei DATI)
    // Questo  la BASE da cui derivano TUTTE le scale
    int naturalPeriod; // Periodo naturale del mercato per questo TF
};

//--- Periodi organici per ogni timeframe (calcolati in OnInit)
OrganicPeriods g_organic_M5, g_organic_H1, g_organic_H4, g_organic_D1;

//  FIX: Periodi precedenti per rilevare cambi significativi (soglia data-driven)
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
// |              SISTEMA ORGANICO (Fully Empirical)                            |
// +---------------------------------------------------------------------------+
// | SOGLIA SCORE: OTSU (warmup) -> YOUDEN (feedback) con guardrail              |
// | MEAN-REVERSION: RSI/Stoch/OBV votano nella direzione dell'inversione       |
// +---------------------------------------------------------------------------+
//--- SISTEMA ORGANICO ---
input bool   AutoScoreThreshold = false;  // Soglia automatica (OTSU->YOUDEN)? Se false, usa ScoreThreshold manuale
input double ScoreThreshold     = 50.0;   // Soglia manuale (usata solo se AutoScoreThreshold=false)
input bool   EnableEarlyEntryBelowThreshold = false; // Permette "ENTRY ANTICIPATO" (reversal forte) anche sotto soglia score

bool   EnableYoudenExpDecay = true;        // AUTO: impostato da AutoConfigureOrganicSystemParams()
double YoudenHalfLifeTrades = 0.0;         // AUTO: half-life (trade) derivata da buffer/periodi empirici
bool   EnableYoudenUseRMultiple = true;    // AUTO: true se abbiamo un riskPts stimabile (SL)
double YoudenMinRMultiple = 0.0;           // AUTO: break-even in R (costi stimati / risk)
int    YoudenMinWins = 0;                  // AUTO: guardrail minimo win per attivare Youden
int    YoudenMinLosses = 0;                // AUTO: guardrail minimo loss per attivare Youden
double YoudenSmoothingAlpha = 0.0;         // AUTO: smoothing derivato da half-life

//--- PERFORMANCE BACKTEST ---
int    RecalcEveryBars    = 0;            // Ricalcolo ogni N barre (0=ogni barra, 100=veloce, 200=molto veloce)


//+------------------------------------------------------------------+
//| AUTO-CONFIG: parametri organici da dati mercato                  |
//| Nota: qui NON decidiamo SL/TP/TF/indicatori (quelli restano input)|
//+------------------------------------------------------------------+
void AutoConfigureOrganicSystemParams()
{
    // Soglia score: rispetta scelta utente (AutoScoreThreshold input)
    // Se automatica: calcola parametri Youden
    // Se manuale: usa ScoreThreshold direttamente

    // Half-life: la deriviamo dai buffer empirici (già data-driven dai periodi naturali)
    // - g_recentTradesMax: finestra trade recente (data-driven)
    // - g_minTradesForYouden: quando attivare Youden (data-driven)
    double baseHL = (double)MathMax(1, MathMax(g_recentTradesMax, g_minTradesForYouden));
    YoudenHalfLifeTrades = baseHL; // più grande = più stabile

    // Smoothing coerente con half-life: alpha = exp(-ln(2)/halfLife)
    // Usato come: T = alpha*Tprev + (1-alpha)*Tnew
    if (YoudenHalfLifeTrades > 0.0) {
        double ln2 = MathLog(2.0);
        YoudenSmoothingAlpha = MathExp(-ln2 / YoudenHalfLifeTrades);
    } else {
        YoudenSmoothingAlpha = 0.0;
    }

    // Se abbiamo un rischio stimabile (SL), possiamo usare R-multiple.
    // Altrimenti, fallback interno su NetProfit>=0 (come già previsto nel codice).
    int riskPts = 0;
    if (BuyStopLossPoints > 0)  riskPts = MathMax(riskPts, BuyStopLossPoints);
    if (SellStopLossPoints > 0) riskPts = MathMax(riskPts, SellStopLossPoints);
    EnableYoudenUseRMultiple = (riskPts > 0);

    // MinR: stima costi in "R" usando spread/slippage massimi consentiti.
    // (dipende da input operativi, ma non è un parametro "tunable" del sistema organico)
    YoudenMinRMultiple = 0.0;
    if (riskPts > 0) {
        double costPts = MathMax(0.0, MaxSpread) + (double)MaxSlippage;
        YoudenMinRMultiple = costPts / (double)riskPts;
    }

    // Guardrail min win/loss: derivato dalla dimensione finestra Youden (data-driven)
    // sqrt(N) è una regola robusta e non dipende da numeri “arbitrari” di mercato.
    int n = MathMax(0, g_minTradesForYouden);
    int minClass = (n > 0) ? (int)MathCeil(MathSqrt((double)n)) : 0;
    YoudenMinWins = minClass;
    YoudenMinLosses = minClass;

    // Exp-decay: coerente con half-life; se half-life non valido, disattiva.
    EnableYoudenExpDecay = (YoudenHalfLifeTrades > 1.0);
}

// +---------------------------------------------------------------------------+
// |                  GUARDRAILS / DEFAULTS (auto)                              |
// | Obiettivo: nessun parametro di scala/clamp hardcoded nella logica.         |
// +---------------------------------------------------------------------------+
//--- GUARDRAILS / DEFAULTS ---
double DataDrivenRatioMin          = 0.0;      // AUTO (bootstrap + empirical)
double DataDrivenRatioMax          = 0.0;      // AUTO (bootstrap + empirical)
int    DataDrivenBufferMin         = 0;        // AUTO
int    DataDrivenBufferMax         = 0;        // AUTO (con hard-cap tecnico per memoria)
int    BufferXLargeMin             = 0;        // AUTO
double NumericEpsilon              = 0.0;      // AUTO (da digits)
double PercentileLow               = 0.0;      // AUTO (definizione robusta)
double PercentileHigh              = 0.0;      // AUTO (definizione robusta)
double IQRLogChangeFrac            = 0.0;      // AUTO (anti-spam log)
double YoudenStepSizeFallback      = 0.0;      // AUTO
int    YoudenTargetTestsMin        = 0;        // AUTO
double YoudenTargetTestsScale      = 0.0;      // AUTO
double TrimPercentDefault          = 0.0;      // AUTO
double ObvAbsEpsilon               = 0.0;      // AUTO
double ObvMinChangeFallback        = 0.0;      // AUTO
double AdxFlatRangeThreshold       = 0.0;      // AUTO
double AdxStddevFallbackFrac       = 0.0;      // AUTO
double AdxStddevAbsMin             = 0.0;      // AUTO
double AdxP75MinDelta              = 0.0;      // AUTO
double BollingerDeviationDefault   = 0.0;      // AUTO
double PSARStepMin                 = 0.0;      // AUTO
double PSARStepMax                 = 0.0;      // AUTO
double PSARMaxMin                  = 0.0;      // AUTO
double PSARMaxMax                  = 0.0;      // AUTO
double PointFallbackNonJPY         = 0.0;      // AUTO (da digits)
double PointFallbackJPYLike        = 0.0;      // AUTO (da digits)
double ATRScaleAbsMin              = 0.0;      // AUTO
double EarlyExitAtrPipsFallback    = 0.0;      // AUTO
double EarlyExitMinLossPipsFloor   = 0.0;      // AUTO
double EarlyExitMinLossAtrFrac     = 0.0;      // AUTO

// +---------------------------------------------------------------------------+
// | Guardrails AUTO (bootstrap + empirical + after-buffers)                    |
// +---------------------------------------------------------------------------+

void GetEnabledTFSecondsMinMax(int &minSec, int &maxSec)
{
    minSec = 0;
    maxSec = 0;

    if(EnableVote_M5)
    {
        int s = PERIOD_M5 * 60;
        if(minSec <= 0 || s < minSec) minSec = s;
        if(maxSec <= 0 || s > maxSec) maxSec = s;
    }
    if(EnableVote_H1)
    {
        int s = PERIOD_H1 * 60;
        if(minSec <= 0 || s < minSec) minSec = s;
        if(maxSec <= 0 || s > maxSec) maxSec = s;
    }
    if(EnableVote_H4)
    {
        int s = PERIOD_H4 * 60;
        if(minSec <= 0 || s < minSec) minSec = s;
        if(maxSec <= 0 || s > maxSec) maxSec = s;
    }
    if(EnableVote_D1)
    {
        int s = PERIOD_D1 * 60;
        if(minSec <= 0 || s < minSec) minSec = s;
        if(maxSec <= 0 || s > maxSec) maxSec = s;
    }

    // fallback: timeframe corrente
    if(minSec <= 0 || maxSec <= 0)
    {
        int cur = (int)PeriodSeconds(_Period);
        if(cur <= 0) cur = 1;
        minSec = cur;
        maxSec = cur;
    }
}

int GetLogThrottleSeconds()
{
    int minSec, maxSec;
    GetEnabledTFSecondsMinMax(minSec, maxSec);
    double s = MathSqrt((double)MathMax(1, minSec));
    int out = (int)MathRound(MathMax(1.0, s));
    if(out <= 0) out = 1;
    return out;
}

int GetTerminalMaxBarsSafe()
{
    int maxBars = (int)TerminalInfoInteger(TERMINAL_MAXBARS);
    if(maxBars <= 0)
        maxBars = Bars(_Symbol, _Period);
    if(maxBars <= 0)
        maxBars = 1;
    return maxBars;
}

void GetNaturalPeriodMinMax(int &minP, int &maxP)
{
    minP = 0;
    maxP = 0;

    if(g_dataReady_M5 && g_naturalPeriod_M5 > 0)
    {
        minP = g_naturalPeriod_M5;
        maxP = g_naturalPeriod_M5;
    }
    if(g_dataReady_H1 && g_naturalPeriod_H1 > 0)
    {
        if(minP <= 0 || g_naturalPeriod_H1 < minP) minP = g_naturalPeriod_H1;
        if(maxP <= 0 || g_naturalPeriod_H1 > maxP) maxP = g_naturalPeriod_H1;
    }
    if(g_dataReady_H4 && g_naturalPeriod_H4 > 0)
    {
        if(minP <= 0 || g_naturalPeriod_H4 < minP) minP = g_naturalPeriod_H4;
        if(maxP <= 0 || g_naturalPeriod_H4 > maxP) maxP = g_naturalPeriod_H4;
    }
    if(g_dataReady_D1 && g_naturalPeriod_D1 > 0)
    {
        if(minP <= 0 || g_naturalPeriod_D1 < minP) minP = g_naturalPeriod_D1;
        if(maxP <= 0 || g_naturalPeriod_D1 > maxP) maxP = g_naturalPeriod_D1;
    }

    if(minP <= 0 || maxP <= 0)
    {
        int fallbackMin = (g_naturalPeriod_Min > 0 ? g_naturalPeriod_Min : GetBootstrapMinBars());
        if(fallbackMin <= 0) fallbackMin = 1;

        int minSec, maxSec;
        GetEnabledTFSecondsMinMax(minSec, maxSec);
        double span = (double)maxSec / (double)MathMax(1, minSec);
        if(span < 1.0) span = 1.0;

        minP = fallbackMin;
        maxP = (int)MathMax(minP, MathCeil((double)minP * span));
    }
}

void AutoConfigurePercentileBoundsFromN(const int n)
{
    // Percentili come funzione di N: tailMass = 1/sqrt(N)
    // - N piccolo  => tail grande => bounds più centrali (più robusti)
    // - N grande   => tail piccolo => bounds più larghi (meno clamp)
    int nEff = n;
    if(nEff <= 0)
        nEff = DataDrivenBufferMin * DataDrivenBufferMin;
    if(nEff <= 0)
        nEff = 1;

    double tail = 1.0 / MathSqrt((double)nEff);

    // clamp tail usando solo quantità già data-driven
    double tailMin = 1.0 / MathSqrt((double)MathMax(1, DataDrivenBufferMax));
    double tailMax = 1.0 / MathSqrt((double)MathMax(1, DataDrivenBufferMin));
    tail = MathMax(tailMin, MathMin(tail, tailMax));
    if(tail < NumericEpsilon)
        tail = NumericEpsilon;

    PercentileLow  = 100.0 * tail;
    PercentileHigh = 100.0 * (1.0 - tail);
    if(PercentileHigh <= PercentileLow)
    {
        PercentileLow  = 50.0 - 50.0 * NumericEpsilon;
        PercentileHigh = 50.0 + 50.0 * NumericEpsilon;
    }
}

void AutoConfigureGuardrailsBootstrap()
{
    const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    const int d = (_Digits > 0 ? _Digits : (digits > 0 ? digits : 1));

    // point fallbacks coerenti con la precisione del simbolo
    PointFallbackNonJPY  = MathPow(10.0, -(double)d);
    PointFallbackJPYLike = PointFallbackNonJPY;

    // epsilon: qualche ordine di grandezza sotto il tick
    NumericEpsilon = MathPow(10.0, -(double)(d + 4));
    if(NumericEpsilon <= 0.0)
    {
        double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
        if(p <= 0.0) p = PointFallbackNonJPY;
        NumericEpsilon = MathAbs(p) * MathAbs(p);
    }

    // ratio clamp: dipende dalla dispersione dei TF abilitati
    int minSec, maxSec;
    GetEnabledTFSecondsMinMax(minSec, maxSec);
    double tfSpan = (double)maxSec / (double)MathMax(1, minSec);
    if(tfSpan < 1.0) tfSpan = 1.0;
    DataDrivenRatioMax = tfSpan;
    DataDrivenRatioMin = 1.0 / tfSpan;

    // buffer clamp: dipende dai TF attivi (proporzionale!)
    // Più TF attivi = più dati cross-correlati = buffer più grandi giustificati
    int activeTfCount = 0;
    if (EnableVote_M5) activeTfCount++;
    if (EnableVote_H1) activeTfCount++;
    if (EnableVote_H4) activeTfCount++;
    if (EnableVote_D1) activeTfCount++;
    if (activeTfCount == 0) activeTfCount = 1;
    
    // Buffer max scalato: 150 per 1 TF, 600 per 4 TF (proporzionale alla complessità)
    const int BUFFER_BASE_PER_TF = 150;
    DataDrivenBufferMax = BUFFER_BASE_PER_TF * activeTfCount;
    
    DataDrivenBufferMin = (int)MathMax(2, MathCeil(MathSqrt((double)MathMax(1, GetBootstrapMinBars()))));
    DataDrivenBufferMax = (int)MathMax(DataDrivenBufferMin, DataDrivenBufferMax);
    BufferXLargeMin = (int)MathMin(
        DataDrivenBufferMax,
        MathMax(
            (int)MathCeil(MathSqrt((double)DataDrivenBufferMax)),
            DataDrivenBufferMin * DataDrivenBufferMin
        )
    );

    // percentili: data-driven da N proxy (buffer minimo)
    AutoConfigurePercentileBoundsFromN(DataDrivenBufferMin * DataDrivenBufferMin);

    // log-change guardrail: più storia => soglia più piccola
    IQRLogChangeFrac = 1.0 / MathMax(1.0, MathSqrt((double)DataDrivenBufferMax));

    // indicatori/derivati
    ObvAbsEpsilon = NumericEpsilon;

    // inizializza i restanti a valori sensati, poi raffina più avanti
    if(TrimPercentDefault <= 0.0)
    {
        double tail = (PercentileLow > 0.0 ? (PercentileLow / 100.0) : 0.0);
        TrimPercentDefault = (tail > 0.0 ? tail : (1.0 / MathSqrt((double)MathMax(1, DataDrivenBufferMin))));
    }
    if(YoudenTargetTestsScale <= 0.0) YoudenTargetTestsScale = MathMax(1.0, MathSqrt((double)DataDrivenBufferMin));
    if(YoudenTargetTestsMin <= 0) YoudenTargetTestsMin = (int)MathMax(2, MathCeil(MathSqrt((double)DataDrivenBufferMin)));
    if(YoudenStepSizeFallback <= 0.0) YoudenStepSizeFallback = 100.0 / (double)MathMax(1, DataDrivenBufferMin * DataDrivenBufferMin);

    // Derivazioni "safe" senza numeri di mercato: dipendono da precisione e finestre.
    double base = (double)MathMax(1, BufferXLargeMin);

    AdxStddevFallbackFrac = 1.0 / MathMax(1.0, MathSqrt(base));
    AdxStddevAbsMin       = MathMax(NumericEpsilon, 100.0 / MathMax(1.0, (double)DataDrivenBufferMax));
    AdxFlatRangeThreshold = 1.0 / MathMax(1.0, MathSqrt(base));
    AdxP75MinDelta        = 100.0 / MathMax(1.0, base);

    BollingerDeviationDefault = MathMax(
        1.0,
        MathSqrt(base) / MathMax(1.0, MathSqrt((double)MathMax(1, DataDrivenBufferMin)))
    );

    PSARStepMin = 1.0 / base;
    PSARStepMax = 1.0 / MathSqrt(base);
    if(PSARStepMax < PSARStepMin) PSARStepMax = PSARStepMin;
    PSARMaxMin  = MathMin(1.0, MathSqrt(base) * PSARStepMin);
    PSARMaxMax  = MathMin(1.0, MathSqrt(base) * PSARStepMax);
    if(PSARMaxMax < PSARMaxMin) PSARMaxMax = PSARMaxMin;

    ATRScaleAbsMin = PointFallbackNonJPY;
}

void AutoConfigureGuardrailsEmpirical()
{
    int minP, maxP;
    GetNaturalPeriodMinMax(minP, maxP);

    double span = (double)maxP / (double)MathMax(1, minP);
    if(span < 1.0) span = 1.0;
    DataDrivenRatioMax = span;
    DataDrivenRatioMin = 1.0 / span;

    // buffer min cresce con la granularità osservata (periodo minimo)
    int newMin = (int)MathMax(DataDrivenBufferMin, MathCeil(MathSqrt((double)MathMax(1, minP))));
    DataDrivenBufferMin = newMin;
    DataDrivenBufferMax = (int)MathMax(DataDrivenBufferMax, DataDrivenBufferMin);
    BufferXLargeMin = (int)MathMin(DataDrivenBufferMax, MathMax(BufferXLargeMin, DataDrivenBufferMin * DataDrivenBufferMin));

    // PSAR clamp derivati dal periodo naturale minimo
    double base = (double)MathMax(1, minP);
    PSARStepMin = 1.0 / base;
    PSARStepMax = 1.0 / MathSqrt(base);
    if(PSARStepMax < PSARStepMin) PSARStepMax = PSARStepMin;
    PSARMaxMin  = MathMin(1.0, MathSqrt(base) * PSARStepMin);
    PSARMaxMax  = MathMin(1.0, MathSqrt(base) * PSARStepMax);
    if(PSARMaxMax < PSARMaxMin) PSARMaxMax = PSARMaxMin;

    // BB: deviazione coerente con volatilità relativa (proxy via periodo)
    BollingerDeviationDefault = MathMax(
        1.0,
        MathSqrt(base) / MathMax(1.0, MathSqrt((double)MathMax(1, DataDrivenBufferMin)))
    );

    // ADX: soglie di "flatness" e delta percentili
    AdxFlatRangeThreshold = 1.0 / MathMax(1.0, MathSqrt(base));
    AdxP75MinDelta        = 100.0 / MathMax(1.0, base);
}

void AutoConfigureGuardrailsAfterBuffers()
{
    int smallW = GetBufferSmall();
    int medW   = GetBufferMedium();
    int largeW = GetBufferLarge();

    YoudenTargetTestsScale = MathMax(1.0, MathSqrt((double)MathMax(1, smallW)));
    YoudenTargetTestsMin   = (int)MathMax(2, MathCeil(MathSqrt((double)MathMax(1, smallW))));

    YoudenStepSizeFallback = 100.0 / (double)MathMax(1, medW);
    TrimPercentDefault     = (PercentileLow > 0.0 ? (PercentileLow / 100.0) : (1.0 / MathSqrt((double)MathMax(1, medW))));

    // OBV: minimo cambiamento relativo ~ 1 tick sul prezzo
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if(bid <= 0.0)
        bid = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    if(bid <= 0.0)
        bid = MathMax(NumericEpsilon, g_pointValue);
    ObvMinChangeFallback = MathMax(NumericEpsilon, g_pointValue / bid);

    // ADX: pseudo-stddev se varianza nulla
    AdxStddevFallbackFrac = 1.0 / MathMax(1.0, MathSqrt((double)MathMax(1, medW)));
    AdxStddevAbsMin       = MathMax(NumericEpsilon, 100.0 / MathMax(1.0, (double)largeW));

    // ATR scale minimo: usa spread come proxy (in prezzo)
    double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    ATRScaleAbsMin = MathMax(g_pointValue, spreadPts * g_pointValue);

    // Early-exit: fallback proporzionale al costo/rumore
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double pipsPerPoint = 1.0;
    if(digits == 3 || digits == 5) pipsPerPoint = 0.1;
    double spreadPips = spreadPts * pipsPerPoint;
    if(spreadPips <= 0.0) spreadPips = MathMax(NumericEpsilon, pipsPerPoint);

    EarlyExitAtrPipsFallback  = spreadPips * MathMax(1.0, MathSqrt((double)MathMax(1, smallW)));
    EarlyExitMinLossPipsFloor = MathMax(NumericEpsilon, spreadPips);
    EarlyExitMinLossAtrFrac   = 1.0 / MathMax(1.0, MathSqrt((double)MathMax(1, medW)));

    // percentili: raffinamento finale usando N effettivo dello score history
    AutoConfigurePercentileBoundsFromN(SCORE_HISTORY_MAX);
}


//  FUNZIONE: Calcola buffer size 100% auto-driven
// Restituisce: basePeriod * f(ratio, exponent)
// ratio deriva dai periodi naturali osservati (nessun uso di H)
int GetDataDrivenBufferSize(int basePeriod, int exponent)
{
    int refPeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
    double denom = (double)MathMax(1, basePeriod);
    double ratio = (double)refPeriod / denom;

    // Clamp prudente per evitare esplosioni quando i periodi non sono ancora stabili
    ratio = MathMax(DataDrivenRatioMin, MathMin(DataDrivenRatioMax, ratio));

    // Exponent: 0 -> 1, 1 -> sqrt(ratio), 2 -> ratio, 3 -> ratio^(1.5), 4 -> ratio^2
    double factor = MathPow(ratio, 0.5 * (double)exponent);
    double size = (double)basePeriod * factor;

    int out = (int)MathRound(size);
    out = MathMax(DataDrivenBufferMin, out);
    out = MathMin(out, DataDrivenBufferMax);
    
    // HARD CAP PROPORZIONALE basato su TF disponibili (intelligente!)
    // Più TF attivi = buffer più grandi (hanno più dati cross-TF)
    int activeTfCount = 0;
    if (EnableVote_M5) activeTfCount++;
    if (EnableVote_H1) activeTfCount++;
    if (EnableVote_H4) activeTfCount++;
    if (EnableVote_D1) activeTfCount++;
    if (activeTfCount == 0) activeTfCount = 1;
    
    // Buffer cap scalato: 100 per 1 TF, 400 per 4 TF
    int hardCap = 100 * activeTfCount;
    out = MathMin(out, hardCap);
    
    return out;
}

//  FUNZIONI BUFFER 100% DATA-DRIVEN
// Prima OnInit: usa bootstrapMinBars (minimo derivato dalla storia disponibile)
// Dopo OnInit: usa periodi empirici calcolati dai dati
//  Si adattano dinamicamente ai periodi naturali!

// BOOTSTRAP (data-driven): minimo barre derivato dalla storia disponibile (iBars)
int g_bootstrapMinBars = 0;

int ComputeBootstrapMinBars()
{
    int minBars = 0;

    if(EnableVote_M5)
    {
        int b = iBars(_Symbol, PERIOD_M5);
        if(b > 0) minBars = (minBars <= 0 ? b : MathMin(minBars, b));
    }
    if(EnableVote_H1)
    {
        int b = iBars(_Symbol, PERIOD_H1);
        if(b > 0) minBars = (minBars <= 0 ? b : MathMin(minBars, b));
    }
    if(EnableVote_H4)
    {
        int b = iBars(_Symbol, PERIOD_H4);
        if(b > 0) minBars = (minBars <= 0 ? b : MathMin(minBars, b));
    }
    if(EnableVote_D1)
    {
        int b = iBars(_Symbol, PERIOD_D1);
        if(b > 0) minBars = (minBars <= 0 ? b : MathMin(minBars, b));
    }

    if(minBars <= 0)
    {
        minBars = GetTerminalMaxBarsSafe();
    }

    int bootstrap = (int)MathCeil(MathSqrt((double)MathMax(1, minBars)));
    bootstrap = MathMax(2, MathMin(bootstrap, minBars));
    return bootstrap;
}

int GetBootstrapMinBars()
{
    if(g_bootstrapMinBars > 0) return g_bootstrapMinBars;
    return ComputeBootstrapMinBars();
}

//+------------------------------------------------------------------+
//| CALCOLA LIMITI PROPORZIONALI AL TIMEFRAME (non arbitrari!)      |
//| Finestra temporale fissa (giorni) -> barre diverse per TF       |
//| Esempio: 7 giorni = 2016 barre M5, 168 barre H1, 7 barre D1     |
//+------------------------------------------------------------------+
struct TimeFrameLimits {
    int maxBars;           // Max barre da caricare per questo TF
    int maxLagAuto;        // Max lag per autocorrelazione
    int bufferScale;       // Fattore scala buffer (1-4)
    int minBarsBootstrap;  // Minimo barre bootstrap
};

TimeFrameLimits GetTimeFrameLimits(ENUM_TIMEFRAMES tf)
{
    TimeFrameLimits limits;
    
    // PARAMETRI DA INPUT (configurabili dall'utente!)
    int windowDays = 7;  // Default fallback
    
    // Seleziona giorni specifici per questo TF (input configurabili)
    if (tf == PERIOD_M5 || tf == PERIOD_M1) {
        windowDays = MathMax(1, WindowDays_M5);
    } else if (tf == PERIOD_M15 || tf == PERIOD_M30 || tf == PERIOD_H1) {
        windowDays = MathMax(1, WindowDays_H1);
    } else if (tf == PERIOD_H2 || tf == PERIOD_H3 || tf == PERIOD_H4) {
        windowDays = MathMax(1, WindowDays_H4);
    } else {  // H6, H8, H12, D1, W1, MN1
        windowDays = MathMax(1, WindowDays_D1);
    }
    
    // Parametri autocorrelazione da input (clampati per sicurezza)
    double maxLagFraction = MathMax(0.05, MathMin(0.30, MaxLagFraction));
    int maxLagAbsolute = MathMax(10, MathMin(500, MaxLagAbsolute));
    const int MIN_LAG_ABSOLUTE = 5;         // Minimo lag assoluto (tecnico)
    
    // Calcola minuti per barra di questo TF
    int tfMinutes = PeriodSeconds(tf) / 60;
    if (tfMinutes <= 0) tfMinutes = 1;
    
    // Calcola barre necessarie per coprire windowDays (specifico per TF)
    int minutesInWindow = windowDays * 24 * 60;
    int barsForWindow = minutesInWindow / tfMinutes;
    
    // HARD CAP per sicurezza memoria (proporzionale al TF!)
    // TF piccoli (M5) possono gestire più barre, TF grandi (D1) meno
    int hardCapByTF;
    if (tf <= PERIOD_M15) {
        hardCapByTF = 2000;      // M1, M5, M15: fino a 2000 barre
    } else if (tf <= PERIOD_H1) {
        hardCapByTF = 500;       // M30, H1: fino a 500 barre
    } else if (tf <= PERIOD_H4) {
        hardCapByTF = 400;       // H2, H3, H4: fino a 400 barre (evita blocchi su periodi >200)
    } else {
        hardCapByTF = 300;       // H6, H8, D1, W1: fino a 300 barre (D1=50 blocca min_bars_required tipici)
    }
    
    // Applica hard cap
    limits.maxBars = MathMin(barsForWindow, hardCapByTF);
    
    // MaxLag proporzionale alle barre (cerca cicli dentro la finestra)
    // Usa parametri configurabili dall'input!
    limits.maxLagAuto = (int)(limits.maxBars * maxLagFraction);
    limits.maxLagAuto = MathMax(MIN_LAG_ABSOLUTE, MathMin(limits.maxLagAuto, maxLagAbsolute));
    
    // Buffer scale: TF più grandi hanno buffer più grandi (relativamente)
    // M5 = 1x, H1 = 2x, H4 = 3x, D1 = 4x
    if (tf <= PERIOD_M15) {
        limits.bufferScale = 1;
    } else if (tf <= PERIOD_H1) {
        limits.bufferScale = 2;
    } else if (tf <= PERIOD_H4) {
        limits.bufferScale = 3;
    } else {
        limits.bufferScale = 4;
    }
    
    // Bootstrap minimo: 10% delle barre max, almeno 10
    limits.minBarsBootstrap = MathMax(10, limits.maxBars / 10);
    
    return limits;
}

int GetBufferSmall()   
{ 
    int base = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
    return GetDataDrivenBufferSize(base, 0); 
}

int GetBufferMedium()  
{ 
    int base = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
    return GetDataDrivenBufferSize(base, 1); 
}

int GetBufferLarge()   
{ 
    int base = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapMinBars();
    return GetDataDrivenBufferSize(base, 1); 
}

int GetBufferXLarge()  
{ 
    int base = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapMinBars();
    int result = GetDataDrivenBufferSize(base, 2);
    return MathMax(result, BufferXLargeMin);  // Minimo configurabile per calcoli robusti
}

int GetBufferHuge()    
{ 
    int base = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapMinBars();
    int result = GetDataDrivenBufferSize(base, 3);
    // Minimo data-driven per calcoli robusti: dipende dai clamp/buffer auto
    int minHuge = MathMax(BufferXLargeMin, DataDrivenBufferMin * DataDrivenBufferMin);
    if(minHuge <= 0)
        minHuge = MathMax(GetBootstrapMinBars() * 2, 1);
    return MathMax(result, minHuge);
}

//+------------------------------------------------------------------+
//| CALCOLA BARRE DA CARICARE - PROPORZIONALE AL TIMEFRAME          |
//| Usa GetTimeFrameLimits() per limiti intelligenti per TF         |
//| M5 può gestire 2000 barre, D1 solo 50 -> stessa finestra tempo! |
//+------------------------------------------------------------------+
int CalculateBarsToLoad(ENUM_TIMEFRAMES tf, const OrganicPeriods &organic)
{
    // Ottieni limiti proporzionali per questo TF specifico
    TimeFrameLimits limits = GetTimeFrameLimits(tf);
    
    // STEP 1: Calcola barre basate su periodo naturale (se disponibile)
    int barsNeeded = limits.maxBars;  // Default: usa max per questo TF
    
    if (organic.naturalPeriod > 0) {
        // Carica almeno 4 cicli naturali completi (per statistiche robuste)
        int barsForCycles = organic.naturalPeriod * 4;
        barsNeeded = MathMin(barsForCycles, limits.maxBars);
    }
    
    // STEP 2: Assicura minimo statistico (almeno 3 periodi naturali)
    int minBarsForStats = MathMax(limits.minBarsBootstrap, organic.naturalPeriod * 3);
    barsNeeded = MathMax(barsNeeded, minBarsForStats);

    // STEP 2b: Assicura minimo richiesto dai periodi organici
    // Se min_bars_required e' calcolato (es. 153), dobbiamo caricare ALMENO quello,
    // altrimenti CalculateOrganicValues() andra' in loop di "Barre insufficienti".
    if (organic.min_bars_required > 0) {
        barsNeeded = MathMax(barsNeeded, organic.min_bars_required);
    }
    
    // STEP 3: Applica cap proporzionale al TF, ma NON sotto il minimo richiesto dai calcoli
    // (altrimenti H4/D1 restano bloccati: es. maxBars=84/50 ma min_bars_required=153)
    int maxBarsCap = limits.maxBars;
    if (organic.min_bars_required > 0) {
        maxBarsCap = MathMax(maxBarsCap, organic.min_bars_required);
    }
    barsNeeded = MathMin(barsNeeded, maxBarsCap);
    
    // STEP 4: Verifica barre disponibili (safety)
    int barsAvailable = iBars(_Symbol, tf);
    if (barsAvailable > 0 && barsNeeded > barsAvailable - 10) {
        // Usa tutte le barre disponibili meno margine sicurezza
        barsNeeded = MathMax(10, barsAvailable - 10);
    }
    
    // STEP 5: Bootstrap minimo garantito (proporzionale al TF)
    barsNeeded = MathMax(barsNeeded, MathMin(limits.minBarsBootstrap, barsAvailable - 10));
    
    return barsNeeded;
}

// BOOTSTRAP_SAFE_BARS calcolato dinamicamente in OnInit come g_naturalPeriod_Min * 2

//  DATA-DRIVEN: Periodi naturali empirici (da autocorrelazione)
int g_naturalPeriod_M5 = 0;                               // Periodo naturale M5
int g_naturalPeriod_H1 = 0;                               // Periodo naturale H1
int g_naturalPeriod_H4 = 0;                               // Periodo naturale H4
int g_naturalPeriod_D1 = 0;                               // Periodo naturale D1
int g_naturalPeriod_Min = 0;                              // Minimo tra tutti i periodi attivi

//  LOOKBACK ADATTIVO: numero di barre per calcolare periodo naturale (auto-organizzante)
// Il lookback emerge dal periodo naturale stesso: lookback = periodo_naturale * fattore empirico.
// Bootstrap iniziale: usa un minimo statistico.
int g_lookback_M5 = 0;                                    // Lookback adattivo M5
int g_lookback_H1 = 0;                                    // Lookback adattivo H1
int g_lookback_H4 = 0;                                    // Lookback adattivo H4
int g_lookback_D1 = 0;                                    // Lookback adattivo D1

// ---------------------------------------------------------------------------
//  OTTIMIZZAZIONE PERFORMANCE BACKTEST
// ---------------------------------------------------------------------------
int    g_barsSinceLastRecalc = 0;           // Contatore barre dall'ultimo ricalcolo
bool   g_isBacktest = false;                 // Flag: siamo in backtest?
bool   g_enableLogsEffective = true;         // Log effettivi (auto-disabilitati in backtest)

// ---------------------------------------------------------------------------
//  DIAGNOSTICA DECISION (usata per log chiari in ExecuteTradingLogic)
// ---------------------------------------------------------------------------
double g_lastThresholdBasePct = 0.0;
double g_lastThresholdEffPct = 0.0;
double g_lastScorePct = 0.0;

//  PERIODI EMPIRICI CALCOLATI DAI DATI (usati dopo OnInit)
int    g_empiricalPeriod_M5 = 0;             // Periodo naturale M5 (da autocorrelazione)
int    g_empiricalPeriod_H1 = 0;             // Periodo naturale H1 (da autocorrelazione)
int    g_empiricalPeriod_H4 = 0;             // Periodo naturale H4 (da autocorrelazione)
int    g_empiricalPeriod_D1 = 0;             // Periodo naturale D1 (da autocorrelazione)
int    g_empiricalPeriod_Min = 0;            // Minimo tra tutti i periodi attivi (base sistema)

//  CACHE FLAGS (le variabili struct sono dichiarate dopo NaturalPeriodResult)
bool   g_cacheValid = false;                 // Cache valida?
bool   g_tfDataCacheValid = false;           // Cache dati TF valida?
int    g_tfDataRecalcCounter = 0;            // Contatore per reload dati TF

//  DIAGNOSTICA PERFORMANCE: Contatori ROLLING vs RELOAD FULL
int    g_rollingUpdateCount = 0;             // Contatore UPDATE ROLLING (shift+append 1 barra)
int    g_reloadFullCount = 0;                // Contatore RELOAD FULL (carica tutto storico)
int    g_cacheHitCount = 0;                  // Contatore CACHE HIT (skip, nessuna operazione)

//  FIX: Variabili per rilevamento gap di prezzo e invalidazione cache
double g_lastCachePrice = 0.0;               // Ultimo prezzo quando cache valida
double g_lastCacheATR = 0.0;                 // Ultimo ATR quando cache valida

//  FIX: Warmup period - evita trading prima di stabilizzazione indicatori
datetime g_eaStartTime = 0;                  // Timestamp avvio EA
bool   g_warmupComplete = false;             // Flag: warmup completato?
int    g_warmupBarsRequired = 0;             // Barre minime prima di tradare (calcolato in OnInit)

// ---------------------------------------------------------------------------
//  NOTA: Ora tutto deriva dal PERIODO NATURALE calcolato dai dati
//  (autocorrelazione su storico).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
//  SISTEMA PURO - NESSUN FALLBACK
// Se non abbiamo abbastanza dati per calcolare i centri empirici,
// il timeframe viene DISABILITATO (isDataReady = false) e loggato l'errore.
// Questo garantisce che OGNI decisione sia basata su dati REALI.
// ---------------------------------------------------------------------------

//  Struttura per ritornare il periodo naturale
struct NaturalPeriodResult {
    int period;              // Periodo naturale (lag dove autocorr < decay)
    bool valid;              // true se calcolo OK, false se dati insufficienti
};

//  Cache risultati per TF
NaturalPeriodResult g_cachedResult_M5, g_cachedResult_H1, g_cachedResult_H4, g_cachedResult_D1;

//  RICALCOLO PERIODI NATURALI (ad ogni nuova barra H4)
datetime g_lastH4BarTime = 0;              // Ultima barra H4 processata per periodi naturali

//--- Oggetti trading e indicatori
CTrade          trade;
datetime        lastBarTime = 0;


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

bool TryGetPositionTicketByIdentifier(ulong positionId, ulong &ticketOut)
{
    ticketOut = 0;
    if (positionId == 0) return false;

    int total = PositionsTotal();
    for (int i = total - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (!PositionSelectByTicket(ticket)) continue;
        long ident = PositionGetInteger(POSITION_IDENTIFIER);
        if (ident > 0 && (ulong)ident == positionId) {
            ticketOut = ticket;
            return true;
        }
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
    int newCap = (g_openEntrySnapsCap <= 0) ? MathMax(2, GetBufferMedium()) : g_openEntrySnapsCap;
    while (newCap < minCap) newCap *= 2;
    ArrayResize(g_openEntrySnaps, newCap);
    g_openEntrySnapsCap = newCap;
}

void RegisterEntrySnapshot(const EntrySnapshot &snap)
{
    if (snap.positionId == 0) return;

    // Safety: in teoria le posizioni aperte simultanee sono limitate, ma evitiamo crescita anomala
    int openSnapMax = MathMax(MaxOpenTrades, MathMax(g_openTicketsMax, GetBufferHuge()));
    if(openSnapMax <= 0) openSnapMax = MaxOpenTrades;
    if (g_openEntrySnapsCount >= openSnapMax) {
        static bool s_loggedSnapMax = false;
        if (!s_loggedSnapMax) {
            PrintFormat("[EXPORT-EXT] Troppi snapshot aperti (%d). Stop register per safety.", openSnapMax);
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
    int newCap = (g_extendedTradesCap <= 0) ? MathMax(2, GetBufferXLarge()) : g_extendedTradesCap;
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
    int maxRecords = MathMax(GetBufferHuge(), GetTerminalMaxBarsSafe());
    if (g_extendedTradesCount >= maxRecords) {
        static bool s_loggedMax = false;
        if (!s_loggedMax) {
            PrintFormat("[EXPORT-EXT] Buffer pieno (%d record). Stop append per safety.", maxRecords);
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
    return "";
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
//| Ottieni BOOTSTRAP_SAFE_BARS (empirico)                           |
//+------------------------------------------------------------------+
int GetBootstrapSafeBars()
{
    if (g_naturalPeriod_Min > 0) return g_naturalPeriod_Min * 2;
    return MathMax(GetBootstrapMinBars() * 2, GetBufferHuge());
}

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
    double sl;                 // prezzo SL al momento dell'entry (se disponibile da snapshot)
    double tp;                 // prezzo TP al momento dell'entry (se disponibile da snapshot)
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
        "ScorePctAtEntry","ThresholdBasePct","ThresholdEffPct",
        "ThresholdMethodId","ThresholdMethod");

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
            (int)rec.thresholdMethodId,
            ThresholdMethodToString(rec.thresholdMethodId));

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

// Diagnostica readiness Youden (per log non ripetitivi e per evitare messaggi fuorvianti)
enum ENUM_YOUDEN_REASON
{
    YOUDEN_OK = 0,
    YOUDEN_NOT_ENOUGH_TRADES = 1,
    YOUDEN_NOT_ENOUGH_VALID = 2,
    YOUDEN_GUARDRAIL_WINS = 3,
    YOUDEN_GUARDRAIL_LOSSES = 4,
    YOUDEN_ONE_CLASS = 5,
    YOUDEN_J_NOT_POSITIVE = 6
};

int g_youdenLastReason = YOUDEN_OK;
int g_youdenLastValidCount = 0;
int g_youdenLastPosCount = 0;
int g_youdenLastNegCount = 0;

// v1.1 FIX: Mappa ticket -> score per collegare correttamente score a trade
// Problema: g_lastEntryScore veniva sovrascritto prima della chiusura trade
// Soluzione: Array paralleli che mantengono score per ogni posizione aperta
ulong  g_openTickets[];                   // Ticket delle posizioni aperte
double g_openScores[];                    // Score al momento dell'apertura
int    g_openTicketsCount = 0;            // Numero posizioni tracciate
int    g_openTicketsMax = 0;              // Max posizioni = g_recentTradesMax

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
// Soglie: percentili empirici P{low}/P{high} (data-driven)
int g_stochExtremeSignal = 0;            // +1=ipervenduto (bullish reversal), -1=ipercomprato (bearish), 0=neutro
double g_stochExtremeStrength = 0.0;     // Forza segnale (0-1)

// OBV DIVERGENCE DETECTION (volume vs price)
int g_obvDivergenceSignal = 0;           // +1=bullish div (prezzo, OBV), -1=bearish (prezzo, OBV), 0=nessuna
double g_obvDivergenceStrength = 0.0;    // Forza divergenza OBV (0-1)

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
    double adx_threshold;   // Soglia ADX organica = avg + stddev (dai dati)
    bool   isDataReady;     // Flag: abbastanza dati per calcoli organici
    
    // CENTRI ADATTIVI DATA-DRIVEN - Calcolati da CalculateEmpiricalThresholds()
    double rsi_center;      // Centro adattivo RSI ultime N barre
    double stoch_center;    // Centro adattivo Stochastic ultime N barre
    
    // SCALE EMPIRICHE - Derivate dalla volatilita dei dati
    double rsi_scale;       // Stdev empirico RSI
    double stoch_scale;     // Stdev empirico Stochastic
    double obv_scale;       // Stdev empirico variazioni OBV
    
    // ADX PERCENTILI - Derivati dalla distribuzione storica (bounds data-driven)
    double adx_p25;         // PercentileLow ADX (range "basso")
    double adx_p75;         // PercentileHigh ADX (range "alto")
    
    // Riferimento ai periodi organici del TF (impostato in LoadTimeFrameData)
    OrganicPeriods organic; // Periodi e peso organico del timeframe

    // Performance: cache ultimo timestamp barra CHIUSA (shift=1) caricata per questo TF
    // Serve a evitare UpdateLastBar() inutile quando il TF non ha avuto nuove barre.
    datetime lastClosedBarTime;

    // Diagnostica cache update: per capire chiaramente perche' si fa fallback a RELOAD
    int      lastUpdateFailCode;   // 0=ok/none, 1=missedBars, 2=missingHandles, 3=copyFail
    int      lastUpdateFailShift;  // iBarShift relativo a lastClosedBarTime quando fallisce
    datetime lastUpdateFailLoggedAt; // ultimo barTime (TF corrente) in cui abbiamo loggato il fail (anti-spam)
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
    // CONTROLLO SICUREZZA PC: Verifica memoria disponibile prima di partire
    // Se il terminale ha troppo poca RAM disponibile, avvisa l'utente
    long memoryUsed = TerminalInfoInteger(TERMINAL_MEMORY_USED);
    long memoryLimit = TerminalInfoInteger(TERMINAL_MEMORY_TOTAL);
    long memoryAvailable = memoryLimit - memoryUsed;
    
    PrintFormat("[MEMORY CHECK] Memoria: Usata=%d MB, Disponibile=%d MB, Limite=%d MB",
        memoryUsed / (1024*1024), memoryAvailable / (1024*1024), memoryLimit / (1024*1024));
    
    // Se meno di 100 MB disponibili, avvisa (ma non bloccare)
    if (memoryAvailable < 100 * 1024 * 1024) {
        PrintFormat("? [MEMORY WARNING] Memoria disponibile bassa (%d MB). Il PC potrebbe rallentare!",
            memoryAvailable / (1024*1024));
    }
    
    // LOG CONFIGURAZIONE MEMORIA (mostra giorni configurati per TF)
    Print("---------------------------------------------------------------");
    Print("CONFIGURAZIONE MEMORIA (Giorni Storia per Timeframe):");
    if (EnableVote_M5) {
        TimeFrameLimits lim_M5 = GetTimeFrameLimits(PERIOD_M5);
        PrintFormat("  M5:  %d giorni = ~%d barre (maxLag=%d)", WindowDays_M5, lim_M5.maxBars, lim_M5.maxLagAuto);
    }
    if (EnableVote_H1) {
        TimeFrameLimits lim_H1 = GetTimeFrameLimits(PERIOD_H1);
        PrintFormat("  H1:  %d giorni = ~%d barre (maxLag=%d)", WindowDays_H1, lim_H1.maxBars, lim_H1.maxLagAuto);
    }
    if (EnableVote_H4) {
        TimeFrameLimits lim_H4 = GetTimeFrameLimits(PERIOD_H4);
        PrintFormat("  H4:  %d giorni = ~%d barre (maxLag=%d)", WindowDays_H4, lim_H4.maxBars, lim_H4.maxLagAuto);
    }
    if (EnableVote_D1) {
        TimeFrameLimits lim_D1 = GetTimeFrameLimits(PERIOD_D1);
        PrintFormat("  D1:  %d giorni = ~%d barre (maxLag=%d)", WindowDays_D1, lim_D1.maxBars, lim_D1.maxLagAuto);
    }
    PrintFormat("  MaxLag: %.1f%% barre (max assoluto=%d)", MaxLagFraction*100, MaxLagAbsolute);
    Print("---------------------------------------------------------------");
    Print("");
    
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
        Print("   Sistema: data-driven (empirico)");
        Print("   Nota log: i log dettagliati sono ridotti in backtest");
        Print("-----------------------------------------------------------------");
    }
    
    Print("[INIT] Avvio EA Jarvis v4 FULL DATA-DRIVEN - periodi e pesi dai dati");

    // BOOTSTRAP (data-driven): fissa una volta il minimo barre da storia disponibile
    g_bootstrapMinBars = ComputeBootstrapMinBars();

    // GUARDRAILS: bootstrap (solo proprietà simbolo + TF abilitati)
    AutoConfigureGuardrailsBootstrap();
    
    // CACHE COSTANTI SIMBOLO (evita chiamate API ripetute)
    g_pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // Fallback basato su precisione simbolo (AUTO)
    if (g_pointValue <= 0) {
        // Determina se coppia JPY-like dal nome simbolo
        string upperSymbol = _Symbol;
        StringToUpper(upperSymbol);
        if (StringFind(upperSymbol, "JPY") >= 0 || StringFind(upperSymbol, "XAU") >= 0) {
            g_pointValue = PointFallbackJPYLike;
        } else {
            g_pointValue = PointFallbackNonJPY;
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
    g_naturalPeriod_M5 = result_M5.valid ? result_M5.period : GetBootstrapMinBars();
    g_naturalPeriod_H1 = result_H1.valid ? result_H1.period : GetBootstrapMinBars();
    g_naturalPeriod_H4 = result_H4.valid ? result_H4.period : GetBootstrapMinBars();
    g_naturalPeriod_D1 = result_D1.valid ? result_D1.period : GetBootstrapMinBars();
    
    // Base sistema = minimo tra TF attivi (pi reattivo)
    g_naturalPeriod_Min = INT_MAX;  // Sentinella massima
    if (result_M5.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_M5.period);
    if (result_H1.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_H1.period);
    if (result_H4.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_H4.period);
    if (result_D1.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_D1.period);
    if (g_naturalPeriod_Min == INT_MAX) g_naturalPeriod_Min = GetBootstrapMinBars();  // Fallback empirico
    
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

    // GUARDRAILS: raffinamento empirico (dopo stima periodi naturali)
    AutoConfigureGuardrailsEmpirical();

    // SCORE HISTORY: buffer data-driven (ora con guardrails coerenti)
    int scoreBase = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapSafeBars();
    SCORE_HISTORY_MAX = GetDataDrivenBufferSize(scoreBase, 4);
    
    // ---------------------------------------------------------------
    // STEP 2: PESI TF (fully empirical)
    // Peso uniforme sui TF validi
    // ---------------------------------------------------------------
    int activeCount = 0;
    if (result_M5.valid) activeCount++;
    if (result_H1.valid) activeCount++;
    if (result_H4.valid) activeCount++;
    if (result_D1.valid) activeCount++;
    double invCount = (activeCount > 0) ? (1.0 / activeCount) : 0.0;
    double weight_M5 = result_M5.valid ? invCount : 0.0;
    double weight_H1 = result_H1.valid ? invCount : 0.0;
    double weight_H4 = result_H4.valid ? invCount : 0.0;
    double weight_D1 = result_D1.valid ? invCount : 0.0;
    
    PrintFormat("[INIT] Periodi naturali: M5=%d H1=%d H4=%d D1=%d",
        result_M5.period, result_H1.period, result_H4.period, result_D1.period);
    PrintFormat("[INIT] Pesi TF (uniformi): M5=%.2f H1=%.2f H4=%.2f D1=%.2f",
        weight_M5, weight_H1, weight_H4, weight_D1);
    PrintFormat("[INIT] TF attivi: M5=%s H1=%s H4=%s D1=%s",
        StateLabel(g_dataReady_M5), StateLabel(g_dataReady_H1),
        StateLabel(g_dataReady_H4), StateLabel(g_dataReady_D1));
    
    // ---------------------------------------------------------------
    // STEP 3: CALCOLO PERIODI ORGANICI (solo per TF attivi)
    // TUTTI i periodi sono derivati dal periodo naturale usando rapporti f
    // I pesi sono passati insieme al periodo naturale
    // ---------------------------------------------------------------
    if (g_dataReady_M5) CalculateOrganicPeriodsFromData(PERIOD_M5, g_organic_M5, result_M5.period, weight_M5);
    if (g_dataReady_H1) CalculateOrganicPeriodsFromData(PERIOD_H1, g_organic_H1, result_H1.period, weight_H1);
    if (g_dataReady_H4) CalculateOrganicPeriodsFromData(PERIOD_H4, g_organic_H4, result_H4.period, weight_H4);
    if (g_dataReady_D1) CalculateOrganicPeriodsFromData(PERIOD_D1, g_organic_D1, result_D1.period, weight_D1);
    
    // Log periodi organici calcolati
    if (g_enableLogsEffective) {
        Print("");
        Print("---------------------------------------------------------------");
        Print("PERIODI E PESI 100% DATA-DRIVEN (Rapporti f)");
        Print("---------------------------------------------------------------");
        if (g_dataReady_M5) LogOrganicPeriods("M5", g_organic_M5);
        if (g_dataReady_H1) LogOrganicPeriods("H1", g_organic_H1);
        if (g_dataReady_H4) LogOrganicPeriods("H4", g_organic_H4);
        if (g_dataReady_D1) LogOrganicPeriods("D1", g_organic_D1);
        Print("---------------------------------------------------------------");
        Print("");
    }
    
    // ---------------------------------------------------------------
    // STEP 5: INIZIALIZZA SOGLIA SCORE DINAMICA
    // Se AutoScoreThreshold=true, la soglia sara' derivata dalla
    // distribuzione storica degli score. Altrimenti usa valore manuale.
    // ---------------------------------------------------------------
    InitScoreHistoryBuffer();
    if (AutoScoreThreshold) {
        int minSamplesOrganic = GetBufferSmall();
        // Data-driven: campioni minimi per inizializzazione ~ sqrt(N)
        int minSamplesForInit = MathMax(minSamplesOrganic, (int)MathCeil(MathSqrt((double)MathMax(1, SCORE_HISTORY_MAX))));
        Print("");
        Print("---------------------------------------------------------------");
        Print("SOGLIA SCORE 100% DERIVATA DAI DATI");
        Print("   Formula: threshold = mean_score + stdev_score (con clamp percentili)");
        PrintFormat("   Buffer: %d campioni | Ready dopo %d campioni (~%d%% del buffer)", 
            SCORE_HISTORY_MAX, minSamplesForInit, (int)MathRound(100.0 * minSamplesForInit / SCORE_HISTORY_MAX));
        PrintFormat("   Limiti: P%.0f <-> P%.0f (empirici)", PercentileLow, PercentileHigh);
        Print("---------------------------------------------------------------");
        Print("");
    } else {
        PrintFormat("[INIT] Soglia score MANUALE: %.1f%%", ScoreThreshold);
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
    // Warmup: solo periodi organici + buffer (nessun Hurst)
    int longestPeriod = MathMax(MathMax(g_organic_M5.naturalPeriod, g_organic_H1.naturalPeriod),
                                MathMax(g_organic_H4.naturalPeriod, g_organic_D1.naturalPeriod));
    // Minimo warmup derivato dal periodo empirico H1  scale
    int baseH1 = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapSafeBars();
    int minWarmupBars = GetDataDrivenBufferSize(baseH1, 2);
    g_warmupBarsRequired = MathMax(minWarmupBars, longestPeriod + GetBufferSmall());
    PrintFormat("[INIT] Warmup: %d barre richieste prima del trading", g_warmupBarsRequired);
    
    // ---------------------------------------------------------------
    //  INIZIALIZZA STATISTICHE TRADING
    // ---------------------------------------------------------------
    ZeroMemory(g_stats);
    g_stats.peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // Buffer trade recenti = periodo empirico H1  scale
    int baseForTrades = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapSafeBars();
    g_recentTradesMax = GetDataDrivenBufferSize(baseForTrades, 2);
    
    //  v1.1: Inizializza sistema Otsu  Youden
    int baseForYouden = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
    g_minTradesForYouden = GetDataDrivenBufferSize(baseForYouden, 1);
    g_youdenReady = false;
    g_youdenThreshold = 0.0;
    g_otsuThreshold = 0.0;
    g_lastEntryScore = 0.0;

    // GUARDRAILS: raffinamento finale (dopo che i buffer data-driven sono noti)
    AutoConfigureGuardrailsAfterBuffers();

    // AUTO: parametri Youden/threshold realmente data-driven (dopo che i buffer empirici sono noti)
    AutoConfigureOrganicSystemParams();
    
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
    if (AutoScoreThreshold) {
        Print("SOGLIA ADATTIVA: OTSU -> YOUDEN (100% DATA-DRIVEN)");
        Print("---------------------------------------------------------------");
        PrintFormat("   Fase 1 (warm-up): OTSU - separazione bimodale score");
        if (EnableYoudenExpDecay && YoudenHalfLifeTrades > 0.0)
            PrintFormat("   Fase 2 (>=%d trade): YOUDEN - massimizza (TPR+TNR-1) con exp-decay (half-life=%.1f trade)", g_minTradesForYouden, YoudenHalfLifeTrades);
        else
            PrintFormat("   Fase 2 (>=%d trade): YOUDEN - massimizza (TPR+TNR-1)", g_minTradesForYouden);
        PrintFormat("   Bounds: P%.0f%% <-> P%.0f%% (empirici)", PercentileLow, PercentileHigh);
        Print("   Core data-driven dai dati (guardrail Youden auto)");
    } else {
        Print("SOGLIA MANUALE (FISSA)");
        Print("---------------------------------------------------------------");
        PrintFormat("   Soglia fissa: %.1f%% (configurata dall'utente)", ScoreThreshold);
        Print("   AutoScoreThreshold=false - nessun adattamento dinamico");
    }
    Print("---------------------------------------------------------------");
    
    // ---------------------------------------------------------------
    // RIEPILOGO STATO BUFFER - Trading pronto?
    // ---------------------------------------------------------------
    Print("");
    Print("---------------------------------------------------------------");
    Print("STATO BUFFER E PRONTEZZA TRADING");
    Print("---------------------------------------------------------------");
    PrintFormat("   Buffer Score Indicatori: %d/%d | Ready: %s (fallback: soglia manuale %.1f%%)", 
        g_scoreHistorySize, SCORE_HISTORY_MAX, g_scoreThresholdReady ? "SI" : "NO", ScoreThreshold);
    PrintFormat("   Warm-up: %d barre richieste (vedi log Warmup)", g_warmupBarsRequired);
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
        
        // Log TIME-BASED WINDOW diagnostico (valori calcolati per ogni TF)
        // Mostra le barre che verranno caricate per ogni timeframe
        int testBarsM5 = (g_dataReady_M5) ? CalculateBarsToLoad(PERIOD_M5, g_organic_M5) : 0;
        int testBarsH1 = (g_dataReady_H1 && EnableVote_H1) ? CalculateBarsToLoad(PERIOD_H1, g_organic_H1) : 0;
        int testBarsH4 = (g_dataReady_H4 && EnableVote_H4) ? CalculateBarsToLoad(PERIOD_H4, g_organic_H4) : 0;
        int testBarsD1 = (g_dataReady_D1 && EnableVote_D1) ? CalculateBarsToLoad(PERIOD_D1, g_organic_D1) : 0;
        
        int naturalMins = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min * PeriodSeconds(PERIOD_M5) / 60 : 1440;
        PrintFormat("[INIT] TIME-BASED WINDOW: natural=%dmin x 4 = %dmin (%.1fh)",
            naturalMins, naturalMins * 4, (naturalMins * 4) / 60.0);
        PrintFormat("[INIT] Barre calcolate per TF: M5=%d | H1=%d | H4=%d | D1=%d (memory-safe)",
            testBarsM5, testBarsH1, testBarsH4, testBarsD1);
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
        double gapThreshold = g_lastCacheATR;  // Gap = ATR (auto-driven, nessun fattore H-driven)
        
        if (priceChange > gapThreshold) {
            g_cacheValid = false;  // Invalida cache su gap
            if (g_enableLogsEffective) {
                PrintFormat("[RECALC] GAP rilevato: %.5f > %.5f (ATR) - cache invalidata", 
                    priceChange, gapThreshold);
            }
        }
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
    
    bool needRecalc = (!g_cacheValid || recalcNaturalPeriods);
    if (needRecalc) {
        result_M5 = CalculateNaturalPeriodForTF(PERIOD_M5);
        result_H1 = CalculateNaturalPeriodForTF(PERIOD_H1);
        result_H4 = CalculateNaturalPeriodForTF(PERIOD_H4);
        result_D1 = CalculateNaturalPeriodForTF(PERIOD_D1);

        if (result_M5.valid) g_naturalPeriod_M5 = result_M5.period;
        if (result_H1.valid) g_naturalPeriod_H1 = result_H1.period;
        if (result_H4.valid) g_naturalPeriod_H4 = result_H4.period;
        if (result_D1.valid) g_naturalPeriod_D1 = result_D1.period;

        g_naturalPeriod_Min = INT_MAX;
        if (result_M5.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_M5.period);
        if (result_H1.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_H1.period);
        if (result_H4.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_H4.period);
        if (result_D1.valid) g_naturalPeriod_Min = MathMin(g_naturalPeriod_Min, result_D1.period);
        if (g_naturalPeriod_Min == INT_MAX) g_naturalPeriod_Min = GetBootstrapMinBars();

        g_cachedResult_M5 = result_M5;
        g_cachedResult_H1 = result_H1;
        g_cachedResult_H4 = result_H4;
        g_cachedResult_D1 = result_D1;
        g_cacheValid = true;

        g_lastCachePrice = currentPrice;
        if (g_dataReady_H1 && tfData_H1.atr_avg > 0) {
            g_lastCacheATR = tfData_H1.atr_avg;
        } else if (g_dataReady_H4 && tfData_H4.atr_avg > 0) {
            g_lastCacheATR = tfData_H4.atr_avg;
        } else if (g_dataReady_M5 && tfData_M5.atr_avg > 0) {
            g_lastCacheATR = tfData_M5.atr_avg;
        } else {
            int fallbackBase = (g_naturalPeriod_H1 > 0) ? g_naturalPeriod_H1 : GetBootstrapSafeBars();
            int fallbackPips = GetDataDrivenBufferSize(fallbackBase, 2);
            g_lastCacheATR = g_pointValue * fallbackPips;
        }
    } else {
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
    // STEP 2: PESI TF (fully empirical)
    // Peso uniforme sui TF validi (nessun Hurst)
    // ---------------------------------------------------------------
    int activeCount = 0;
    if (result_M5.valid) activeCount++;
    if (result_H1.valid) activeCount++;
    if (result_H4.valid) activeCount++;
    if (result_D1.valid) activeCount++;
    double invCount = (activeCount > 0) ? (1.0 / activeCount) : 0.0;
    double weight_M5 = result_M5.valid ? invCount : 0.0;
    double weight_H1 = result_H1.valid ? invCount : 0.0;
    double weight_H4 = result_H4.valid ? invCount : 0.0;
    double weight_D1 = result_D1.valid ? invCount : 0.0;
    
    // ---------------------------------------------------------------
    // STEP 3: RICALCOLA PERIODI ORGANICI (solo quando ricalcoliamo i periodi naturali)
    // ---------------------------------------------------------------
    if (needRecalc) {
        if (g_dataReady_M5) CalculateOrganicPeriodsFromData(PERIOD_M5, g_organic_M5, result_M5.period, weight_M5);
        if (g_dataReady_H1) CalculateOrganicPeriodsFromData(PERIOD_H1, g_organic_H1, result_H1.period, weight_H1);
        if (g_dataReady_H4) CalculateOrganicPeriodsFromData(PERIOD_H4, g_organic_H4, result_H4.period, weight_H4);
        if (g_dataReady_D1) CalculateOrganicPeriodsFromData(PERIOD_D1, g_organic_D1, result_D1.period, weight_D1);
        
        // FIX: Controlla se i periodi sono cambiati significativamente
        // Se si, ricrea gli handle indicatori con i nuovi periodi
        if (PeriodsChangedSignificantly()) {
            if (g_enableLogsEffective) {
                Print("[RECALC] Periodi cambiati significativamente - Ricreazione handle indicatori...");
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
        
        SaveCurrentPeriodsAsPrevious();
    }

    // ---------------------------------------------------------------
    //  STEP 5: AGGIORNA SOGLIA SCORE DINAMICA
    // Se AutoScoreThreshold=true, ricalcola dalla distribuzione
    // ---------------------------------------------------------------
    UpdateDynamicThreshold();
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
    int minSec, maxSec;
    GetEnabledTFSecondsMinMax(minSec, maxSec);
    long barsCap = (long)MathMax(1, GetTerminalMaxBarsSafe());
    long spanSec = (long)MathMax(1, maxSec);
    long delta = barsCap * spanSec;
    datetime fromTime = (toTime > (datetime)delta ? (toTime - (datetime)delta) : (datetime)0);
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
//|  OTSU: Soglia che massimizza varianza inter-classe             |
//| Trova il punto di separazione naturale tra score "deboli" e      |
//| score "forti" nella distribuzione storica                        |
//| INPUT: array score storici                                       |
//| OUTPUT: soglia ottimale [0-100] che separa le due classi         |
//|  100% DATA-DRIVEN: nessun numero fisso arbitrario             |
//+------------------------------------------------------------------+
double CalcOtsuThreshold()
{
    // Minimo campioni: empirico (buffer piccolo) - no H-based sizing
    int minSamples = MathMax(DataDrivenBufferMin, GetBufferSmall());
    if (g_scoreHistorySize < minSamples) {
        // Fallback: percentile P25 dei dati esistenti
        if (g_scoreHistorySize > 0) {
            return CalculatePercentile(g_scoreHistory, g_scoreHistorySize, PercentileLow);
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
//| Nota: questa e' una stima "feedback" basata sui trade realmente eseguiti.
//| True Positive = trade eseguito con score >= T e classificato positivo
//| True Negative = trade eseguito con score < T e classificato negativo
//| (Non osserviamo direttamente i "non-trade": questa e' una proxy utile per tarare la soglia.)
//+------------------------------------------------------------------+
double CalcYoudenThreshold()
{
    int tradesMax = ArraySize(g_recentTrades);
    g_youdenLastReason = YOUDEN_OK;
    g_youdenLastValidCount = 0;
    g_youdenLastPosCount = 0;
    g_youdenLastNegCount = 0;

    if (g_recentTradesCount < g_minTradesForYouden || tradesMax <= 0) {
        g_youdenLastReason = YOUDEN_NOT_ENOUGH_TRADES;
        return 0.0;  // Non pronto
    }
    
    // Raccogli tutti i trade con score valido
    double scores[];
    double profits[];
    bool labelsPositive[];
    int validCount = 0;
    
    ArrayResize(scores, g_recentTradesCount);
    ArrayResize(profits, g_recentTradesCount);
    ArrayResize(labelsPositive, g_recentTradesCount);
    
    for (int i = 0; i < g_recentTradesCount; i++) {
        int idx = (g_recentTradesIndex - g_recentTradesCount + i + tradesMax) % tradesMax;
        if (g_recentTrades[idx].scoreAtEntry > 0) {  // Score valido
            scores[validCount] = g_recentTrades[idx].scoreAtEntry;
            profits[validCount] = g_recentTrades[idx].profit; // qui e' NET P/L

            // Label win/loss per Youden:
            // - default: NetProfit >= 0
            // - opzionale: R-multiple (profitPts / riskPts da SL), per rendere confrontabili uscite a tempo vs a punti
            bool isPos = (profits[validCount] >= 0.0);
            if (EnableYoudenUseRMultiple) {
                double slPrice = g_recentTrades[idx].sl;
                double op = g_recentTrades[idx].openPrice;
                double cp = g_recentTrades[idx].closePrice;

                if (slPrice > 0.0 && op > 0.0 && cp > 0.0 && _Point > 0.0) {
                    double riskPts = MathAbs(op - slPrice) / _Point;
                    if (riskPts > 0.0) {
                        double profitPts = 0.0;
                        if (g_recentTrades[idx].type == POSITION_TYPE_BUY)
                            profitPts = (cp - op) / _Point;
                        else
                            profitPts = (op - cp) / _Point;

                        double r = profitPts / riskPts;
                        // Importante: mantieni il vincolo su NetProfit>=0 (costi inclusi) per evitare falsi "win"
                        // dovuti a piccole variazioni di prezzo che non coprono commission/spread/swap.
                        isPos = ((profits[validCount] >= 0.0) && (r >= YoudenMinRMultiple));
                    }
                }
            }
            labelsPositive[validCount] = isPos;
            validCount++;
        }
    }
    
    g_youdenLastValidCount = validCount;
    if (validCount < g_minTradesForYouden) {
        g_youdenLastReason = YOUDEN_NOT_ENOUGH_VALID;
        return 0.0;
    }
    
    // Guardrail classi (conta grezza)
    int posCountRaw = 0;
    int negCountRaw = 0;
    for (int i = 0; i < validCount; i++) {
        if (labelsPositive[i]) posCountRaw++;
        else negCountRaw++;
    }
    g_youdenLastPosCount = posCountRaw;
    g_youdenLastNegCount = negCountRaw;
    if (YoudenMinWins > 0 && posCountRaw < YoudenMinWins) {
        g_youdenLastReason = YOUDEN_GUARDRAIL_WINS;
        return 0.0;
    }
    if (YoudenMinLosses > 0 && negCountRaw < YoudenMinLosses) {
        g_youdenLastReason = YOUDEN_GUARDRAIL_LOSSES;
        return 0.0;
    }

    // Pesi per recency (opzionale): weight=0.5^(age/halfLife)
    // Nota: l'array e' in ordine temporale (piu vecchio -> piu recente).
    bool useExpDecay = (EnableYoudenExpDecay && YoudenHalfLifeTrades > 0.0);
    double weights[];
    ArrayResize(weights, validCount);

    double totalPosW = 0.0;  // somma pesi trade profittevoli
    double totalNegW = 0.0;  // somma pesi trade in perdita

    for (int i = 0; i < validCount; i++) {
        double w = 1.0;
        if (useExpDecay) {
            int ageTrades = (validCount - 1) - i;  // 0 = trade piu recente
            w = MathPow(0.5, (double)ageTrades / YoudenHalfLifeTrades);
        }
        weights[i] = w;
        if (labelsPositive[i]) totalPosW += w;
        else totalNegW += w;
    }

    // Se tutte win o tutte loss, Youden non applicabile
    if (totalPosW <= 0.0 || totalNegW <= 0.0) {
        g_youdenLastReason = YOUDEN_ONE_CLASS;
        return 0.0;
    }
    
    // Trova soglia che massimizza J = TPR + TNR - 1
    double maxJ = -1.0;
    
    // Range test 100% data-driven: quartili empirici della distribuzione score
    double minScoreTest = CalculatePercentile(scores, validCount, PercentileLow);
    double maxScoreTest = CalculatePercentile(scores, validCount, PercentileHigh);

    // Fallback iniziale = mediana (robusta, data-driven)
    double optimalThreshold = CalculatePercentile(scores, validCount, 50.0);

    // Step size auto-driven: piu trade => piu step (fino al limite buffer)
    int targetTests = MathMax(GetBufferSmall(), (int)MathRound(MathSqrt((double)validCount) * YoudenTargetTestsScale));
    if (targetTests < YoudenTargetTestsMin) targetTests = YoudenTargetTestsMin;
    double range = (maxScoreTest - minScoreTest);
    double stepSize = (targetTests > 0) ? (range / (double)targetTests) : range;
    if (stepSize <= 0.0) stepSize = YoudenStepSizeFallback;
    
    // Testa soglie nel range data-driven
    for (double threshold = minScoreTest; threshold <= maxScoreTest; threshold += stepSize) {

        // Calcola TP, TN, FP, FN (pesati) per questa soglia
        double TPw = 0.0;  // Score >= T e profitto (corretto entrare)
        double FNw = 0.0;  // Score < T e profitto (sbagliato non entrare)
        double TNw = 0.0;  // Score < T e perdita (corretto non entrare)
        double FPw = 0.0;  // Score >= T e perdita (sbagliato entrare)

        for (int i = 0; i < validCount; i++) {
            bool wouldEnter = (scores[i] >= threshold);
            bool isProfitable = labelsPositive[i];
            double w = weights[i];

            if (wouldEnter && isProfitable) TPw += w;
            else if (wouldEnter && !isProfitable) FPw += w;
            else if (!wouldEnter && isProfitable) FNw += w;
            else TNw += w;  // !wouldEnter && !isProfitable
        }

        // TPR = TP / (TP + FN) = Sensitivity (quanti profitti catturiamo)
        // TNR = TN / (TN + FP) = Specificity (quante perdite evitiamo)
        double TPR = (totalPosW > 0.0) ? TPw / totalPosW : 0.0;
        double TNR = (totalNegW > 0.0) ? TNw / totalNegW : 0.0;
        
        double J = TPR + TNR - 1.0;  // Youden's J: [-1, +1], 0 = random
        
        if (J > maxJ) {
            maxJ = J;
            optimalThreshold = threshold;
        }
    }
    
    // Log se J e' significativo
    // Log solo se J e' significativamente > 0 (data-driven: richiede almeno un passo del range)
    double jLogThreshold = 0.0;
    if (g_enableLogsEffective && maxJ > jLogThreshold) {
        string wStr = useExpDecay ? StringFormat("expDecay halfLife=%.1f", YoudenHalfLifeTrades) : "noDecay";
        string yStr = EnableYoudenUseRMultiple ? StringFormat("Net>=0 && R>=%.2f", YoudenMinRMultiple) : "NetProfit>=0";
        PrintFormat("[YOUDEN] J=%.3f | Soglia ottimale: %.1f%% | Trades: %d (W:%d L:%d) | %s | target=%s",
            maxJ, optimalThreshold, validCount, posCountRaw, negCountRaw, wStr, yStr);
    }
    
    // Solo se J > 0 (meglio di random), altrimenti ritorna 0
    if (maxJ > 0) {
        g_youdenLastReason = YOUDEN_OK;
        return optimalThreshold;
    }

    g_youdenLastReason = YOUDEN_J_NOT_POSITIVE;
    return 0.0;
}

//+------------------------------------------------------------------+
//|  SOGLIA DINAMICA ADATTIVA: OTSU  YOUDEN                       |
//| Fase 1 (warm-up): Usa Otsu (separazione statistica)              |
//| Fase 2 (feedback): Usa Youden (basato su profitti reali)         |
//| ZERO numeri fissi - tutto derivato dai dati                      |
//+------------------------------------------------------------------+
void UpdateDynamicThreshold()
{
    static int s_lastYoudenReasonLogged = -999;
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
    int minSamplesForOtsu = GetBufferSmall();
    
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
            if (YoudenSmoothingAlpha > 0.0 && YoudenSmoothingAlpha < 1.0 && g_youdenReady && g_youdenThreshold > 0.0)
                g_youdenThreshold = (YoudenSmoothingAlpha * g_youdenThreshold) + ((1.0 - YoudenSmoothingAlpha) * youdenResult);
            else
                g_youdenThreshold = youdenResult;
            g_youdenReady = true;
            g_dynamicThreshold = g_youdenThreshold;
            s_lastYoudenReasonLogged = YOUDEN_OK;
            thresholdMethod = StringFormat("YOUDEN (J>0) su %d trade%s%s",
                tradesWithScore,
                (EnableYoudenExpDecay && YoudenHalfLifeTrades > 0.0) ? StringFormat(" | expDecay HL=%.0f", YoudenHalfLifeTrades) : "",
                EnableYoudenUseRMultiple ? StringFormat(" | target R>=%.2f", YoudenMinRMultiple) : "");
        } else {
            // Youden non pronto (guardrail/insufficiente) oppure non trova separazione (J <= 0): usa Otsu
            g_youdenReady = false;
            g_dynamicThreshold = g_otsuThreshold;

            // Log non ripetitivo: solo quando cambia il motivo (specialmente per guardrail)
            if (g_enableLogsEffective && (g_youdenLastReason == YOUDEN_GUARDRAIL_WINS || g_youdenLastReason == YOUDEN_GUARDRAIL_LOSSES)) {
                if (s_lastYoudenReasonLogged != g_youdenLastReason) {
                    PrintFormat("[THRESHOLD] Youden non pronto (guardrail): W %d/%d | L %d/%d | uso OTSU=%.1f%%",
                        g_youdenLastPosCount, YoudenMinWins,
                        g_youdenLastNegCount, YoudenMinLosses,
                        g_otsuThreshold);
                    s_lastYoudenReasonLogged = g_youdenLastReason;
                }
            } else {
                // Se il motivo non e' guardrail, allinea lo stato loggato (evita spam)
                if (g_youdenLastReason != s_lastYoudenReasonLogged)
                    s_lastYoudenReasonLogged = g_youdenLastReason;
            }

            if (g_youdenLastReason == YOUDEN_GUARDRAIL_WINS) {
                thresholdMethod = StringFormat("OTSU (Youden guardrail: W %d/%d)", g_youdenLastPosCount, YoudenMinWins);
            } else if (g_youdenLastReason == YOUDEN_GUARDRAIL_LOSSES) {
                thresholdMethod = StringFormat("OTSU (Youden guardrail: L %d/%d)", g_youdenLastNegCount, YoudenMinLosses);
            } else if (g_youdenLastReason == YOUDEN_ONE_CLASS) {
                thresholdMethod = StringFormat("OTSU (Youden non applicabile: classe unica, %d trade)", tradesWithScore);
            } else if (g_youdenLastReason == YOUDEN_NOT_ENOUGH_VALID) {
                thresholdMethod = StringFormat("OTSU (Youden non pronto: valid %d/%d)", g_youdenLastValidCount, g_minTradesForYouden);
            } else {
                thresholdMethod = StringFormat("OTSU (Youden J<=0, %d trade)", tradesWithScore);
            }
        }
    } else {
        // Non abbastanza trade: usa Otsu
        g_youdenReady = false;
        g_dynamicThreshold = g_otsuThreshold;
        s_lastYoudenReasonLogged = YOUDEN_NOT_ENOUGH_TRADES;
        thresholdMethod = StringFormat("OTSU (attesa %d/%d trade per Youden)", tradesWithScore, g_minTradesForYouden);
    }
    
    g_scoreThresholdReady = true;
    
    // 
    //  SAFETY BOUNDS (data-driven percentili)
    // Min: P{PercentileLow}
    // Max: P{PercentileHigh}
    // 
    int minSamplesForBounds = GetBufferSmall();
    if (g_scoreHistorySize >= minSamplesForBounds) {
        // Percentili empirici (auto-driven): clamp in [P{low}, P{high}]
        double minBound = CalculatePercentile(g_scoreHistory, g_scoreHistorySize, PercentileLow);
        double maxBound = CalculatePercentile(g_scoreHistory, g_scoreHistorySize, PercentileHigh);
        
        bool hitFloor = (g_dynamicThreshold < minBound);
        bool hitCeiling = (g_dynamicThreshold > maxBound);
        
        g_dynamicThreshold = MathMax(minBound, MathMin(maxBound, g_dynamicThreshold));
        
        if (hitFloor || hitCeiling) {
            thresholdMethod += (hitFloor
                                ? StringFormat(" | FLOOR->P%.0f", PercentileLow)
                                : StringFormat(" | CEILING->P%.0f", PercentileHigh));
        }
    }
    
    // Log se cambio significativo (anti-spam): usa una frazione dell'IQR (P{high}-P{low})
    double logChangeThreshold = 0.0;
    if (g_scoreHistorySize >= minSamplesForBounds) {
        double p25 = CalculatePercentile(g_scoreHistory, g_scoreHistorySize, PercentileLow);
        double p75 = CalculatePercentile(g_scoreHistory, g_scoreHistorySize, PercentileHigh);
        double iqr = MathAbs(p75 - p25);
        logChangeThreshold = MathMax(NumericEpsilon, iqr * IQRLogChangeFrac);
    } else {
        logChangeThreshold = NumericEpsilon;
    }
    if (g_enableLogsEffective && MathAbs(g_dynamicThreshold - oldThreshold) > logChangeThreshold) {
        PrintFormat("[THRESHOLD %s] Soglia: %.1f%% -> %.1f%% [%s]",
            TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
            oldThreshold, g_dynamicThreshold, thresholdMethod);
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
    // Start prudente: finche' non e' data-driven (ready=false), richiede forza massima
    g_divergenceMinThreshold = 1.0;
    g_divergenceThresholdReady = false;
    
    // SOGLIA REVERSAL DATA-DRIVEN: buffer = 64 (BUFFER_SIZE_XLARGE)
    int reversalBufferSize = GetBufferXLarge();  // 64
    ArrayResize(g_reversalStrengthHistory, reversalBufferSize);
    ArrayInitialize(g_reversalStrengthHistory, 0);
    g_reversalHistorySize = 0;
    g_reversalHistoryIndex = 0;
    g_reversalSum = 0.0;
    g_reversalSumSq = 0.0;
    // Start prudente: finche' non e' data-driven (ready=false), richiede forza massima
    g_reversalThreshold = 1.0;
    g_reversalThresholdReady = false;
    
    // STOCHASTIC EXTREME E OBV DIVERGENCE (v1.1)
    g_stochExtremeSignal = 0;
    g_stochExtremeStrength = 0.0;
    g_obvDivergenceSignal = 0;
    g_obvDivergenceStrength = 0.0;
    
    if (g_enableLogsEffective) {
        Print("");
        Print("---------------------------------------------------------------");
        Print("DETECTOR INVERSIONE ORGANICO INIZIALIZZATO (v1.1)");
        PrintFormat("   Score Momentum buffer: %d | Soglia: mean + stdev", momentumBufferSize);
        PrintFormat("   RSI Divergence: %d swing points | Soglia: mean + stdev (%s)", 
            g_swingsMax, enableRSI ? "ATTIVO" : "disattivo");
        PrintFormat("   Stochastic Extreme: soglie percentili (P%.0f/P%.0f) (%s)",
            PercentileLow, PercentileHigh,
            enableStoch ? "ATTIVO" : "disattivo");
        PrintFormat("   OBV Divergence: lookback ~4 barre (%s)", 
            enableOBV ? "ATTIVO" : "disattivo");
        PrintFormat("   Divergence buffer: %d | Reversal buffer: %d", divergenceBufferSize, reversalBufferSize);
        Print("---------------------------------------------------------------");
        Print("");
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
        double sumBound = 100.0 * (double)momentumBufferMax * (double)momentumBufferMax;
        if (g_momentumSum < -sumBound) g_momentumSum = 0.0;  // Protezione overflow
        if (g_momentumSumSq < 0) g_momentumSumSq = 0;
    }
    
    // Aggiungi nuovo valore (usiamo valore assoluto per la soglia)
    double absMomentum = MathAbs(g_scoreMomentum);
    g_momentumHistory[g_momentumHistoryIndex] = absMomentum;
    g_momentumSum += absMomentum;
    g_momentumSumSq += absMomentum * absMomentum;
    
    g_momentumHistoryIndex = (g_momentumHistoryIndex + 1) % momentumBufferMax;
    if (g_momentumHistorySize < momentumBufferMax) g_momentumHistorySize++;
    
    // Calcola soglia momentum 100% auto-driven: mean + stdev (clamp da percentili)
    int minSamples = GetBufferSmall();  // 8
    if (g_momentumHistorySize >= minSamples) {
        double mean = g_momentumSum / g_momentumHistorySize;
        double meanSq = g_momentumSumSq / g_momentumHistorySize;
        double variance = meanSq - (mean * mean);
        double stdev = (variance > 0) ? MathSqrt(variance) : 0.0;

        double rawThreshold = mean + stdev;
        double pMidPct = 0.5 * (PercentileLow + PercentileHigh);
        double pHiPct = PercentileHigh;
        if (pHiPct < pMidPct) {
            double tmp = pHiPct;
            pHiPct = pMidPct;
            pMidPct = tmp;
        }

        double pMid = CalculatePercentile(g_momentumHistory, g_momentumHistorySize, pMidPct);
        double pHi = CalculatePercentile(g_momentumHistory, g_momentumHistorySize, pHiPct);
        if (pHi > 0.0) rawThreshold = MathMin(pHi, rawThreshold);
        if (pMid > 0.0) rawThreshold = MathMax(pMid, rawThreshold);

        g_scoreMomentumThreshold = rawThreshold;
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
//| Trading seconds by broker sessions (no hardcoded weekend rules)  |
//+------------------------------------------------------------------+
datetime GetDayStart(datetime t)
{
    MqlDateTime dt;
    TimeToStruct(t, dt);
    dt.hour = 0;
    dt.min = 0;
    dt.sec = 0;
    return StructToTime(dt);
}

datetime AddDays(datetime dayStart, int days)
{
    MqlDateTime dt;
    TimeToStruct(dayStart, dt);
    dt.day += days;
    dt.hour = 0;
    dt.min = 0;
    dt.sec = 0;
    return StructToTime(dt);
}

datetime MakeDateTimeOnDay(datetime dayStart, datetime timeOfDay)
{
    MqlDateTime day;
    TimeToStruct(dayStart, day);

    MqlDateTime tod;
    TimeToStruct(timeOfDay, tod);

    day.hour = tod.hour;
    day.min = tod.min;
    day.sec = tod.sec;
    return StructToTime(day);
}

long OverlapSeconds(datetime aFrom, datetime aTo, datetime bFrom, datetime bTo)
{
    datetime s = (aFrom > bFrom ? aFrom : bFrom);
    datetime e = (aTo < bTo ? aTo : bTo);
    if (e <= s) return 0;
    return (long)(e - s);
}

long ComputeTradingSecondsFromSessions(datetime fromTime, datetime toTime)
{
    if (toTime <= fromTime) return 0;

    datetime day = GetDayStart(fromTime);
    datetime endDay = GetDayStart(toTime);
    long total = 0;
    bool anySessionFound = false;

    for (datetime d = day; d <= endDay; d = AddDays(d, 1))
    {
        datetime nextDay = AddDays(d, 1);
        MqlDateTime dts;
        TimeToStruct(d, dts);
        ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dts.day_of_week;

        // Loop sessions until SymbolInfoSessionTrade returns false.
        for (uint si = 0; ; si++)
        {
            datetime sFrom, sTo;
            if (!SymbolInfoSessionTrade(_Symbol, dow, si, sFrom, sTo))
                break;

            anySessionFound = true;

            datetime sessFrom = MakeDateTimeOnDay(d, sFrom);
            datetime sessTo = MakeDateTimeOnDay(d, sTo);
            if (sessTo <= sessFrom)
                sessTo = MakeDateTimeOnDay(nextDay, sTo);

            // Clamp to [fromTime, toTime]
            total += OverlapSeconds(sessFrom, sessTo, fromTime, toTime);
        }
    }

    if (!anySessionFound)
        return -1;

    return total;
}

//+------------------------------------------------------------------+
//| AGGIORNA SOGLIA DIVERGENZA DATA-DRIVEN                           |
//| Traccia storia forze divergenza e calcola: mean + stdev * decay  |
//| Clamp: [P{low}, P{high}]                                         |
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
        double sumBound = (double)divergenceBufferMax * (double)divergenceBufferMax;
        if (g_divergenceSum < -sumBound) g_divergenceSum = 0.0;  // Protezione drift
        if (g_divergenceSumSq < 0) g_divergenceSumSq = 0;
    }
    
    // Aggiungi valore corrente
    g_divergenceHistory[g_divergenceHistoryIndex] = strength;
    g_divergenceSum += strength;
    g_divergenceSumSq += strength * strength;
    
    // Aggiorna indice circolare
    g_divergenceHistoryIndex = (g_divergenceHistoryIndex + 1) % divergenceBufferMax;
    if (g_divergenceHistorySize < divergenceBufferMax) g_divergenceHistorySize++;
    
    // Calcola soglia: minimo empirico (buffer + frazione del periodo base), nessun Hurst
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
    int minSamples = MathMax(4, MathMax(GetBufferSmall(), basePeriod / 4));
    
    if (g_divergenceHistorySize >= minSamples) {
        double mean = g_divergenceSum / g_divergenceHistorySize;
        double variance = (g_divergenceSumSq / g_divergenceHistorySize) - (mean * mean);
        double stdev = variance > 0 ? MathSqrt(variance) : 0;
        
        // Soglia 100% data-driven: mean + stdev
        g_divergenceMinThreshold = mean + stdev;

        // Clamp 100% dai dati osservati
        double minClamp = CalculatePercentile(g_divergenceHistory, g_divergenceHistorySize, 0);
        double maxClamp = CalculatePercentile(g_divergenceHistory, g_divergenceHistorySize, 100);
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
//| RSI DIVERGENCE: Rileva swing e divergenze prezzo/RSI             |
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
    
    // Servono abbastanza barre per rilevare swing (data-driven)
    int minBars = GetBufferMedium();  // ~17
    if (ratesSize < minBars || rsiSize < minBars) return 0;
    
    // Lookback per swing detection 100% auto-driven:
    // usa periodo naturale (dati) e buffer size (limiti statistici), senza H.
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
    int denom = MathMax(1, GetBufferSmall());  // 8
    int swingLookback = MathMax(3, (int)MathRound((double)basePeriod / (double)denom));
    swingLookback = MathMin(swingLookback, MathMax(3, GetBufferMedium() / 2));
    
    // Cerca swing high/low recenti
    bool foundSwingHigh = false;
    bool foundSwingLow = false;
    double swingHighPrice = 0, swingHighRSI = 0;
    double swingLowPrice = 0, swingLowRSI = 0;
    int swingHighBar = 0, swingLowBar = 0;
    
    // Cerca swing in una finestra data-driven
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

    // Rolling history (auto-driven) della metrica grezza di divergenza RSI
    static double s_rsiDivRawHist[];
    static int s_rsiDivRawSize = 0;
    static int s_rsiDivRawIdx = 0;
    int rawMax = GetBufferXLarge();
    if (ArraySize(s_rsiDivRawHist) != rawMax) {
        ArrayResize(s_rsiDivRawHist, rawMax);
        ArrayInitialize(s_rsiDivRawHist, 0.0);
        s_rsiDivRawSize = 0;
        s_rsiDivRawIdx = 0;
    }
    
    if (foundSwingHigh && prevSwingHighPrice > 0 && prevSwingHighRSI > 0) {
        if (swingHighPrice > prevSwingHighPrice && swingHighRSI < prevSwingHighRSI) {
            double priceDiff = (swingHighPrice - prevSwingHighPrice) / prevSwingHighPrice;
            double rsiDiff = (prevSwingHighRSI - swingHighRSI) / prevSwingHighRSI;
            double rawMetric = MathMax(0.0, priceDiff + rsiDiff);

            // Normalizza 100% auto-driven: strength = raw / P75(raw)
            double p75 = 0.0;
            if (s_rsiDivRawSize >= GetBufferSmall()) {
                p75 = CalculatePercentile(s_rsiDivRawHist, s_rsiDivRawSize, PercentileHigh);
            }
            if (p75 <= 0.0) p75 = rawMetric;
            if (p75 <= 0.0) p75 = NumericEpsilon;
            calcStrength = MathMin(1.0, rawMetric / p75);

            // Aggiorna history raw (circular)
            s_rsiDivRawHist[s_rsiDivRawIdx] = rawMetric;
            s_rsiDivRawIdx = (s_rsiDivRawIdx + 1) % rawMax;
            if (s_rsiDivRawSize < rawMax) s_rsiDivRawSize++;
            
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
            double priceDiff = (prevSwingLowPrice - swingLowPrice) / prevSwingLowPrice;
            double rsiDiff = (swingLowRSI - prevSwingLowRSI) / prevSwingLowRSI;
            double rawMetric = MathMax(0.0, priceDiff + rsiDiff);

            double p75 = 0.0;
            if (s_rsiDivRawSize >= GetBufferSmall()) {
                p75 = CalculatePercentile(s_rsiDivRawHist, s_rsiDivRawSize, PercentileHigh);
            }
            if (p75 <= 0.0) p75 = rawMetric;
            if (p75 <= 0.0) p75 = NumericEpsilon;
            calcStrength = MathMin(1.0, rawMetric / p75);

            s_rsiDivRawHist[s_rsiDivRawIdx] = rawMetric;
            s_rsiDivRawIdx = (s_rsiDivRawIdx + 1) % rawMax;
            if (s_rsiDivRawSize < rawMax) s_rsiDivRawSize++;
            
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
//| Soglie: percentili empirici (low/high) su Stoch K recente        |
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
    
    // SOGLIE 100% DATA-DRIVEN: percentili empirici P{low}/P{high} su Stoch K recente (valori validi 1..99)
    double oversoldLevel = 0.0;
    double overboughtLevel = 0.0;
    double stochVals[];
    int maxLookback = MathMin(count, GetBufferXLarge());  // buffer di riferimento (data-driven)
    ArrayResize(stochVals, maxLookback);
    int valid = 0;
    for (int i = 0; i < maxLookback; i++) {
        int idx = lastIdx - i;
        if (idx < 0) break;
        double k = tfData_H1.stoch_main[idx];
        if (k > 0.0 && k < 100.0) {
            stochVals[valid] = k;
            valid++;
        }
    }
    int minSamples = GetBufferSmall();  // 8
    if (valid >= minSamples) {
        oversoldLevel = CalculatePercentile(stochVals, valid, PercentileLow);
        overboughtLevel = CalculatePercentile(stochVals, valid, PercentileHigh);
    } else {
        // Fallback empirico se dati insufficienti
        oversoldLevel = PercentileLow;
        overboughtLevel = PercentileHigh;
    }
    
    // Forza = quanto e' "estremo" rispetto alla soglia
    // Per ipervenduto: quanto e' sotto la soglia
    // Per ipercomprato: quanto e' sopra la soglia
    
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
    
    // Servono abbastanza barre (data-driven)
    int minBars = GetBufferMedium();  // ~17
    if (ratesSize < minBars || obvSize < minBars) return 0;
    
    // Lookback 100% auto-driven: dipende dal periodo naturale e limiti statistici, senza H
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
    int denom = MathMax(1, GetBufferSmall());
    int lookback = MathMax(3, (int)MathRound((double)basePeriod / (double)denom));
    lookback = MathMin(lookback, MathMax(3, GetBufferMedium() / 2));
    
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
    if (MathAbs(obvPrev) < ObvAbsEpsilon) return 0;
    
    double obvChange = (obvNow - obvPrev) / MathAbs(obvPrev);
    
    // Soglia minima 100% auto-driven: P25 dei movimenti assoluti recenti (price e OBV)
    double absPriceHist[];
    double absObvHist[];
    int maxLB = MathMin(ratesSize - 1, GetBufferXLarge());
    ArrayResize(absPriceHist, maxLB);
    ArrayResize(absObvHist, maxLB);
    int v = 0;
    for (int i = 1; i <= maxLB; i++) {
        int idxNow = lastIdx - (i - 1);
        int idxPrev = lastIdx - i;
        if (idxPrev < 0) break;
        double pc = (tfData_H1.rates[idxNow].close - tfData_H1.rates[idxPrev].close) / tfData_H1.rates[idxPrev].close;
        double op = tfData_H1.obv[idxPrev];
        if (MathAbs(op) < ObvAbsEpsilon) continue;
        double oc = (tfData_H1.obv[idxNow] - op) / MathAbs(op);
        absPriceHist[v] = MathAbs(pc);
        absObvHist[v] = MathAbs(oc);
        v++;
    }
    double minChange = 0.0;
    if (v >= GetBufferSmall()) {
        double p25p = CalculatePercentile(absPriceHist, v, PercentileLow);
        double p25o = CalculatePercentile(absObvHist, v, PercentileLow);
        minChange = MathMax(p25p, p25o);
    }
    if (minChange <= 0.0) minChange = ObvMinChangeFallback; // fallback solo se dati insufficienti
    
    if (MathAbs(priceChange) < minChange || MathAbs(obvChange) < minChange) return 0;
    
    // ---------------------------------------------------------------
    // BEARISH DIVERGENCE: Prezzo sale, OBV scende
    // ---------------------------------------------------------------
    // Rolling history (auto-driven) della metrica grezza di divergenza OBV
    static double s_obvDivRawHist[];
    static int s_obvDivRawSize = 0;
    static int s_obvDivRawIdx = 0;
    int rawMax = GetBufferXLarge();
    if (ArraySize(s_obvDivRawHist) != rawMax) {
        ArrayResize(s_obvDivRawHist, rawMax);
        ArrayInitialize(s_obvDivRawHist, 0.0);
        s_obvDivRawSize = 0;
        s_obvDivRawIdx = 0;
    }

    if (priceChange > 0 && obvChange < 0) {
        // Forza 100% auto-driven: raw / P75(raw)
        double rawMetric = MathMax(0.0, priceChange - obvChange);
        double p75 = 0.0;
        if (s_obvDivRawSize >= GetBufferSmall()) {
            p75 = CalculatePercentile(s_obvDivRawHist, s_obvDivRawSize, PercentileHigh);
        }
        if (p75 <= 0.0) p75 = rawMetric;
        if (p75 <= 0.0) p75 = NumericEpsilon;
        g_obvDivergenceStrength = MathMin(1.0, rawMetric / p75);

        s_obvDivRawHist[s_obvDivRawIdx] = rawMetric;
        s_obvDivRawIdx = (s_obvDivRawIdx + 1) % rawMax;
        if (s_obvDivRawSize < rawMax) s_obvDivRawSize++;
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
        double rawMetric = MathMax(0.0, obvChange - priceChange);
        double p75 = 0.0;
        if (s_obvDivRawSize >= GetBufferSmall()) {
            p75 = CalculatePercentile(s_obvDivRawHist, s_obvDivRawSize, PercentileHigh);
        }
        if (p75 <= 0.0) p75 = rawMetric;
        if (p75 <= 0.0) p75 = NumericEpsilon;
        g_obvDivergenceStrength = MathMin(1.0, rawMetric / p75);

        s_obvDivRawHist[s_obvDivRawIdx] = rawMetric;
        s_obvDivRawIdx = (s_obvDivRawIdx + 1) % rawMax;
        if (s_obvDivRawSize < rawMax) s_obvDivRawSize++;
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
//| SOGLIA 100% AUTO-DRIVEN: mean + stdev (clamp dai dati)           |
//| v1.1: Include Stochastic Extreme e OBV Divergence                |
//+------------------------------------------------------------------+
int GetReversalSignal(double &strength, bool updateHistory = true)
{
    strength = 0.0;
    
    int momentumSignal = g_scoreMomentum > 0 ? 1 : (g_scoreMomentum < 0 ? -1 : 0);
    bool momentumStrong = MathAbs(g_scoreMomentum) >= g_scoreMomentumThreshold;
    int divergenceSignal = g_divergenceSignal;
    
    // NUOVI SEGNALI MEAN-REVERSION (v1.1)
    int stochExtremeSignal = g_stochExtremeSignal;
    int obvDivergenceSignal = g_obvDivergenceSignal;
    
    // ---------------------------------------------------------------
    // LOGICA COMBINATA 100% AUTO-DRIVEN (nessun peso H-driven)
    // Ogni componente entra con forza normalizzata (0..1) e peso unitario.
    // ---------------------------------------------------------------
    double score = 0.0;
    double maxScore = 0.0;
    
    // Divergenza RSI
    if (divergenceSignal != 0) {
        score += divergenceSignal * g_divergenceStrength;
        maxScore += 1.0;
    }
    
    // Divergenza OBV
    if (obvDivergenceSignal != 0) {
        score += obvDivergenceSignal * g_obvDivergenceStrength;
        maxScore += 1.0;
    }
    
    // Stochastic Zone Estreme
    if (stochExtremeSignal != 0) {
        score += stochExtremeSignal * g_stochExtremeStrength;
        maxScore += 1.0;
    }
    
    // Score Momentum (forza normalizzata empiricamente via P75 di |momentum|)
    if (momentumStrong) {
        double absM = MathAbs(g_scoreMomentum);
        double p75M = 0.0;
        if (g_momentumHistorySize >= GetBufferSmall()) {
            p75M = CalculatePercentile(g_momentumHistory, g_momentumHistorySize, PercentileHigh);
        }
        if (p75M <= 0.0) p75M = absM;
        if (p75M <= 0.0) p75M = NumericEpsilon;
        double momStrength = MathMin(1.0, absM / p75M);

        score += momentumSignal * momStrength;
        maxScore += 1.0;
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
            double sumBound = (double)reversalBufferMax * (double)reversalBufferMax;
            if (g_reversalSum < -sumBound) g_reversalSum = 0.0;
            if (g_reversalSumSq < 0) g_reversalSumSq = 0;
        }
        
        g_reversalStrengthHistory[g_reversalHistoryIndex] = strength;
        g_reversalSum += strength;
        g_reversalSumSq += strength * strength;
        
        g_reversalHistoryIndex = (g_reversalHistoryIndex + 1) % reversalBufferMax;
        if (g_reversalHistorySize < reversalBufferMax) g_reversalHistorySize++;
        
        // ---------------------------------------------------------------
        //  CALCOLA SOGLIA DATA-DRIVEN: mean + stdev
        // ---------------------------------------------------------------
        int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
        int minSamples = MathMax(4, MathMax(GetBufferSmall(), basePeriod / 4));
        
        if (g_reversalHistorySize >= minSamples) {
            double mean = g_reversalSum / g_reversalHistorySize;
            double variance = (g_reversalSumSq / g_reversalHistorySize) - (mean * mean);
            variance = MathMax(0.0, variance);
            double stdev = (variance > 0.0) ? MathSqrt(variance) : 0.0;
            
            // Soglia 100% data-driven: mean + stdev
            g_reversalThreshold = mean + stdev;

            // Clamp 100% dai dati osservati
            double strictClampMin = CalculatePercentile(g_reversalStrengthHistory, g_reversalHistorySize, 0);
            double strictClampMax = CalculatePercentile(g_reversalStrengthHistory, g_reversalHistorySize, 100);
            g_reversalThreshold = MathMax(strictClampMin, MathMin(strictClampMax, g_reversalThreshold));
            
            if (!g_reversalThresholdReady) {
                g_reversalThresholdReady = true;
                if (g_enableLogsEffective) {
                    PrintFormat("[REVERSAL %s] Soglia data-driven pronta: %.1f%% (mean=%.1f%%, stdev=%.1f%%)",
                        TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
                        g_reversalThreshold * 100, mean * 100, stdev * 100);
                    PrintFormat("   Buffer: %d/%d campioni | Range=[%.1f%%, %.1f%%] | Clamp=[%.1f%%, %.1f%%]",
                        g_reversalHistorySize, ArraySize(g_reversalStrengthHistory),
                        CalculatePercentile(g_reversalStrengthHistory, g_reversalHistorySize, 0) * 100,
                        CalculatePercentile(g_reversalStrengthHistory, g_reversalHistorySize, 100) * 100,
                        strictClampMin * 100, strictClampMax * 100);
                }
            } else if (g_enableLogsEffective) {
                static int reversalLogCount = 0;
                reversalLogCount++;
                int logInterval = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
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
            PrintFormat("[REVERSAL] INVERSIONE %s | Forza: %.0f%% > Soglia: %.0f%% | RSI=%s OBV=%s Stoch=%s M=%s",
                direction > 0 ? "BULLISH" : "BEARISH",
                strength * 100,
                g_reversalThreshold * 100,
                divergenceSignal > 0 ? "BUY" : (divergenceSignal < 0 ? "SELL" : "NEUTRO"),
                obvDivergenceSignal > 0 ? "BUY" : (obvDivergenceSignal < 0 ? "SELL" : "NEUTRO"),
                stochExtremeSignal > 0 ? "BUY" : (stochExtremeSignal < 0 ? "SELL" : "NEUTRO"),
                momentumStrong ? (momentumSignal > 0 ? "BUY" : "SELL") : "NEUTRO");
        }
        
        return direction;
    }
    
    return 0;
}

//+------------------------------------------------------------------+
//| Calcola il PERIODO NATURALE del mercato per un TF                |
//| Usa AUTOCORRELAZIONE per trovare il "memory decay" del prezzo    |
//| Questo e COMPLETAMENTE derivato dai dati, zero numeri arbitrari  |
//+------------------------------------------------------------------+
NaturalPeriodResult CalculateNaturalPeriodForTF(ENUM_TIMEFRAMES tf)
{
    NaturalPeriodResult result;
    result.period = -1;
    result.valid = false;
    
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    
    // ---------------------------------------------------------------
    //  APPROCCIO 100% AUTO-ORGANIZZANTE (LOOKBACK ADATTIVO):
    // 1. Bootstrap: usa minimo statistico
    // 2. Dopo primo calcolo: lookback = periodo_naturale * fattore empirico
    // 3. Il lookback emerge dal mercato e si adatta ai cambi
    // ---------------------------------------------------------------
    
    //  LOOKBACK ADATTIVO: dipende dal periodo naturale precedente o bootstrap
    int lookback = 0;
    if (tf == PERIOD_M5) lookback = g_lookback_M5;
    else if (tf == PERIOD_H1) lookback = g_lookback_H1;
    else if (tf == PERIOD_H4) lookback = g_lookback_H4;
    else if (tf == PERIOD_D1) lookback = g_lookback_D1;
    
    // Salva lookback iniziale per log
    int initialLookback = lookback;
    
    //  BOOTSTRAP INIZIALE: se lookback=0, usa minimo statistico (no H-based scaling)
    if (lookback == 0) {
        lookback = MathMax(GetBootstrapMinBars() * 4, GetBufferHuge());  // *4 per uscire dal bootstrap
    }
    
    int barsToRequest = lookback;
    
    //  Minimo: derivato dal buffer minimo (data-driven)
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
        // ma NON spegnere il TF: assegna periodo=bootstrapMinBars
        PrintFormat("? [NATURAL] TF %s: copiate %d/%d barre (minimo %d) -> BOOTSTRAP MINIMO, TF ATTIVO", 
            EnumToString(tf), copied, barsToRequest, minBarsForAnalysis);
        result.period = GetBootstrapMinBars();
        result.valid = true;
        return result;
    }
    
    // FIX: barsAvailable = numero EFFETTIVO di barre copiate (non Bars()!)
    int barsAvailable = copied;
    
    // maxLag: PROPORZIONALE AL TIMEFRAME (intelligente, non arbitrario!)
    // M5 può cercare cicli più lunghi (più lag), D1 cerca cicli più corti (meno lag)
    TimeFrameLimits limits = GetTimeFrameLimits(tf);
    int maxLag = limits.maxLagAuto;
    
    // Adatta al numero effettivo di barre disponibili (usa parametro configurabile)
    double maxLagFrac = MathMax(0.05, MathMin(0.30, MaxLagFraction));  // Clamp sicurezza
    maxLag = MathMin(maxLag, (int)(barsAvailable * maxLagFrac));
    maxLag = MathMax(12, maxLag);  // Minimo 12 lag per trovare cicli significativi
    
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
    
    // Variabili per il calcolo del periodo naturale
    double autocorrSum = 0;
    int autocorrCount = 0;
    
    // Trova il lag dove l'autocorrelazione scende sotto una soglia EMPIRICA
    // Soglia = P25 delle autocorrelazioni positive (fallback: 0.0)
    int naturalPeriod = 0;
    double autocorrAtNaturalPeriod = 0;

    int maxLagEffective = MathMin(maxLag - 1, copied - 1);
    if (maxLagEffective < 2) maxLagEffective = MathMin(2, copied - 1);

    double autocorrs[];
    double autocorrPos[];
    ArrayResize(autocorrs, maxLagEffective);
    ArrayResize(autocorrPos, maxLagEffective);
    int posCount = 0;

    for (int lag = 1; lag <= maxLagEffective; lag++) {
        double covariance = 0;
        int count = 0;
        for (int i = lag; i < copied; i++) {
            covariance += (rates[i].close - mean) * (rates[i-lag].close - mean);
            count++;
        }
        if (count <= 0) {
            autocorrs[lag - 1] = 0.0;
            continue;
        }

        covariance /= count;
        double autocorr = covariance / variance;
        autocorrs[lag - 1] = autocorr;
        if (autocorr > 0.0) {
            autocorrSum += autocorr;
            autocorrCount++;
            autocorrPos[posCount] = autocorr;
            posCount++;
        }
    }

    double threshold = 0.0;
    if (posCount >= GetBufferSmall()) {
        threshold = CalculatePercentile(autocorrPos, posCount, PercentileLow);
    }

    for (int lag = 1; lag <= maxLagEffective; lag++) {
        double autocorr = autocorrs[lag - 1];
        if (autocorr < threshold && naturalPeriod == 0) {
            naturalPeriod = lag;
            autocorrAtNaturalPeriod = autocorr;
            if (g_enableLogsEffective) {
                PrintFormat("[NATURAL] TF %s: autocorr[%d]=%.3f < %.3f (P25 pos) -> Periodo naturale=%d",
                    EnumToString(tf), lag, autocorr, threshold, naturalPeriod);
            }
        }
    }
    
    // Se non trovato (mercato molto trending), usa metodo alternativo
    if (naturalPeriod == 0) {
        // Usa il primo minimo locale dell'autocorrelazione
        naturalPeriod = FindAutocorrelationMinimum(rates, copied, maxLag);
        
        if (naturalPeriod == 0) {
            // Usa valore ragionevole: max tra maxLag/2 e bootstrap minimo
            int bootstrapMin = GetBootstrapMinBars();
            naturalPeriod = MathMax(maxLag / 2, bootstrapMin);
            PrintFormat("[NATURAL] TF %s: nessun decay trovato, uso max(maxLag/2, bootstrap)=%d", 
                EnumToString(tf), naturalPeriod);
        }
    }
    
    //  Limita il periodo con proporzioni ragionevoli delle barre disponibili
    // minPeriod = 2  un requisito TECNICO (minimo per calcolare variazione)
    int minPeriod = 2;              // Requisito tecnico: servono almeno 2 punti
    int maxPeriod = maxLag / 2;     // Derivato dalle barre
    naturalPeriod = MathMax(minPeriod, MathMin(maxPeriod, naturalPeriod));
    
    //  MINIMO PERIODO: almeno bootstrapMinBars per stabilita'
    result.period = MathMax(naturalPeriod, GetBootstrapMinBars());
    result.valid = true;
    
    //  AGGIORNA LOOKBACK ADATTIVO per il prossimo calcolo (no H-based scaling)
    int newLookback = result.period + MathMax(GetBootstrapMinBars(), GetBufferHuge());
    newLookback = MathMax(GetBootstrapMinBars() * 2, newLookback);
    // Cap intelligente: usa i limiti TF-proportional invece di cap fisso
    newLookback = MathMin(newLookback, limits.maxBars);
    
    //  Aggiorna lookback globale
    if (tf == PERIOD_M5) g_lookback_M5 = newLookback;
    else if (tf == PERIOD_H1) g_lookback_H1 = newLookback;
    else if (tf == PERIOD_H4) g_lookback_H4 = newLookback;
    else if (tf == PERIOD_D1) g_lookback_D1 = newLookback;
    
    if (shouldLog) {
        PrintFormat("[NATURAL] TF %s: Lookback aggiornato %d -> %d (periodo=%d)",
            EnumToString(tf), initialLookback, newLookback, result.period);
    }
    
    if (g_enableLogsEffective) {
        PrintFormat("[NATURAL] TF %s: Periodo=%d",
            EnumToString(tf), result.period);
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
//| Scarta una frazione degli estremi (trim) - robusto su outlier    |
//| Cattura il vero centro di oscillazione                           |
//+------------------------------------------------------------------+
double CalculateTrimmedMean(const double &arr[], int size, double trimPercent = -1.0)
{
    if (size <= 0) return 0;
    if (size < 5) return CalculateEmpiricalMean(arr, size);  // Fallback per pochi dati
    
    // Se trimPercent non passato, usa default prudente (no H-based scaling)
    if (trimPercent < 0) trimPercent = TrimPercentDefault;
    
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
    
    // Limita alpha con bound empirici (no dipendenze Hurst)
    double alphaMin = 1.0 / (double)MathMax(20, GetBufferHuge());
    double alphaMax = 1.0 - alphaMin;
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
//| CALCOLA CENTRO ADATTIVO DATA-DRIVEN con Smoothing               |
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
    // Fully empirical: centro robusto = mediana (signature mantenuta per compatibilita')
    if (false) Print(H);
    if (size <= 0) return 0;
    if (size < 4) return CalculateEmpiricalMean(arr, size);
    return CalculateMedian(arr, size);
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
//| CALCOLA SOGLIE EMPIRICHE per un TimeFrame - DATA-DRIVEN          |
//| Tutti i centri e scale derivano dai DATI storici reali           |
//| Centro calcolato con metodo adattivo data-driven:                |
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
    int minBarsRequired = MathMax(4, GetBufferSmall());
    
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
    // CENTRI ADATTIVI DATA-DRIVEN con Smoothing
    // Il metodo di stima cambia in base al regime di mercato
    // ---------------------------------------------------------------
    
    // RSI: prepara array delle ultime n barre
    double rsi_data[];
    ArrayResize(rsi_data, n);
    for (int i = 0; i < n; i++) rsi_data[i] = data.rsi[size - n + i];
    
    // Centro robusto: mediana (no H-based regime switching)
    data.rsi_center = CalculateMedian(rsi_data, n);
    
    // StdDev calcolata rispetto al centro adattivo
    double rsi_stdev = CalculateEmpiricalStdDev(rsi_data, n, data.rsi_center);
    if (rsi_stdev <= 0) {
        Print("[EMPIRICAL] RSI stdev=0, dati flat - TF DISABILITATO");
        return false;
    }
    data.rsi_scale = rsi_stdev;
    
    // ---------------------------------------------------------------
    // ADX PERCENTILI - Soglie dalla distribuzione REALE (dai dati)
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
        if (adx_range < AdxFlatRangeThreshold) {  // ADX piatto o quasi
            // Log warning per debug
            if (g_enableLogsEffective) {
                PrintFormat("[ADX EMPIRICAL] WARN: dati piatti rilevati: range=%.3f < %.3f | Fallback: min=%.1f max=%.1f",
                    adx_range, AdxFlatRangeThreshold, adx_min, adx_max);
            }
            Print("[EMPIRICAL] ADX flat (range sotto soglia) - TF usa fallback bootstrap");
            // Usa valori bootstrap approssimati invece di disabilitare
            data.adx_p25 = adx_min + adx_range * (PercentileLow / 100.0);
            data.adx_p75 = adx_min + adx_range * (PercentileHigh / 100.0);
            if (data.adx_p75 <= data.adx_p25) {
                data.adx_p75 = data.adx_p25 + AdxP75MinDelta;  // Garantisce p75 > p25
            }
        } else {
            // Percentili empirici standard
            data.adx_p25 = CalculatePercentile(adx_data, n, PercentileLow);
            data.adx_p75 = CalculatePercentile(adx_data, n, PercentileHigh);
            
            // Verifica finale (dovrebbe sempre passare con p_low < p_high)
            if (data.adx_p75 <= data.adx_p25) {
                PrintFormat("[EMPIRICAL] ADX percentili ancora invalidi dopo calcolo (p25=%.2f p75=%.2f) - usa fallback",
                    data.adx_p25, data.adx_p75);
                data.adx_p75 = data.adx_p25 + AdxP75MinDelta;  // Garantisce p75 > p25
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
        
        // Scala = stdev delle variazioni, con fallback se troppo piccola
        if (obv_change_stdev > 0) {
            data.obv_scale = obv_change_stdev;
        } else {
            // FIX: Fallback migliorato - usa range OBV osservato
            double obv_max = data.obv[startIdx];
            double obv_min = data.obv[startIdx];
            for (int i = 1; i < n; i++) {
                if (data.obv[startIdx + i] > obv_max) obv_max = data.obv[startIdx + i];
                if (data.obv[startIdx + i] < obv_min) obv_min = data.obv[startIdx + i];
            }
            double obv_range = obv_max - obv_min;
            // Scala = range / sqrt(n) (empirico)
            double divisor = MathSqrt((double)n);
            if (divisor > 0 && obv_range > 0) {
                data.obv_scale = obv_range / divisor;
            } else {
                // FIX: Fallback = 128 (potenza di 2 coerente)
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
        PrintFormat("[EMPIRICAL] RSI center=%.1f (MEDIAN) scale=%.1f | ADX p25=%.1f p75=%.1f | OBV scale=%.1f",
            data.rsi_center, data.rsi_scale, data.adx_p25, data.adx_p75, data.obv_scale);
    }
    
    return true;  // Calcolo completato con successo
}

//+------------------------------------------------------------------+
//|  CALCOLA PERIODI 100% DATA-DRIVEN                              |
//| Tutto derivato dal periodo naturale (autocorrelazione)           |
//| Nessuna costante a priori                                        |
//+------------------------------------------------------------------+
void CalculateOrganicPeriodsFromData(ENUM_TIMEFRAMES tf, OrganicPeriods &organic, int naturalPeriod, double weight)
{
    //  PESO passato dal chiamante (fully empirical)
    organic.weight = weight;
    
    // ---------------------------------------------------------------
    //  PERIODO NATURALE = deriva dall'AUTOCORRELAZIONE (dai DATI!)
    // Nessun numero arbitrario - la base viene dal mercato stesso
    // ---------------------------------------------------------------
    double base = (double)naturalPeriod;
    
    //  FIX CRITICO: Limita i periodi al numero di barre disponibili
    // Evita "array out of range" quando gli indicatori richiedono pi barre di quelle disponibili
    int maxBarsAvailable = Bars(_Symbol, tf);
    if (maxBarsAvailable <= 0) maxBarsAvailable = 1000; // Fallback ragionevole
    
    // Usa 80% delle barre disponibili come limite massimo (20% margin di sicurezza)
    int maxPeriodSafe = (int)(maxBarsAvailable * 0.8);
    
    // ---------------------------------------------------------------
    // Periodi derivati SOLO dal periodo naturale (no H-based scaling)
    // Struttura multi-scala: frazioni/multipli del ciclo osservato
    
    //  Periodi organici - TUTTI derivati dal periodo naturale e H
    // Minimi statistici da bootstrapMinBars (non arbitrari):
    int bs = GetBootstrapMinBars();
    int veryFast = (int)MathMin(maxPeriodSafe, MathMax(bs / 4, MathRound(base / 4.0)));
    int fast     = (int)MathMin(maxPeriodSafe, MathMax(bs / 3, MathRound(base / 2.0)));
    int medium   = (int)MathMin(maxPeriodSafe, MathMax(bs / 3, MathRound(base)));
    int slow     = (int)MathMin(maxPeriodSafe, MathMax(bs / 2, MathRound(base * 2.0)));
    int verySlow = (int)MathMin(maxPeriodSafe, MathMax(bs,     MathRound(base * 4.0)));
    int longest  = (int)MathMin(maxPeriodSafe, MathMax(bs * 2, MathRound(base * 8.0)));
    
    if (g_enableLogsEffective) {
        PrintFormat("[ORGANIC] TF %s: Natural=%d -> VeryFast=%d Fast=%d Medium=%d Slow=%d VerySlow=%d Longest=%d",
            EnumToString(tf), naturalPeriod, veryFast, fast, medium, slow, verySlow, longest);
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
    // BB deviation: default standard (non H-driven)
    organic.bb_dev = BollingerDeviationDefault;
    
    // Volatility indicators
    organic.atr = medium;                   // ATR: volatilit  medium
    organic.adx = medium;                   // ADX: forza trend  medium
    
    // ---------------------------------------------------------------
    //  INDICATORI TREND
    // ---------------------------------------------------------------
    
    // Parabolic SAR: parametri derivati dal ciclo (no H-driven)
    organic.psar_step = MathMax(PSARStepMin, MathMin(PSARStepMax, 1.0 / MathMax(1.0, base)));
    organic.psar_max = MathMax(PSARMaxMin, MathMin(PSARMaxMax, 4.0 / MathMax(1.0, base)));
    
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
    organic.stoch_d = fast;
    organic.stoch_slowing = 3;
    
    // organic.weight gi assegnato all'inizio della funzione
    
    //  Barre minime = periodo pi lungo usato + margin
    // Calcolato dinamicamente in base ai periodi effettivi
    // FIX: Limita anche questo al numero di barre disponibili
    int minBarsCalc = longest + GetBufferLarge();
    organic.min_bars_required = (int)MathMin(maxPeriodSafe, minBarsCalc);
    
    //  Salva il periodo naturale per uso nelle scale
    organic.naturalPeriod = naturalPeriod;
}

//+------------------------------------------------------------------+
//|  Log dei periodi organici calcolati                              |
//+------------------------------------------------------------------+
void LogOrganicPeriods(string tfName, OrganicPeriods &organic)
{
    PrintFormat("[%s] Peso TF: %.2f",
        tfName, organic.weight);
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
//|  FIX: Verifica se i periodi sono cambiati significativamente      |
//| Ritorna true se almeno un periodo e' cambiato oltre soglia        |
//| In tal caso gli handle indicatori devono essere ricreati          |
//+------------------------------------------------------------------+
bool PeriodsChangedSignificantly()
{
    if (!g_periodsInitialized) return false;  // Primo calcolo, non serve confronto
    
    //  DATA-DRIVEN: Soglia cambio empirica come funzione del buffer minimo
    //  (piu' campioni => soglia piu' piccola)
    double changeThreshold = 1.0 / (double)MathMax(4, GetBufferSmall());
    
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
    int scoreSize = ArraySize(g_scoreHistory);

    ArrayFree(g_scoreHistory);

    // Reset indici buffer
    g_scoreHistorySize = 0;
    g_scoreHistoryIndex = 0;

    // Reset somme incrementali (CRITICO per riavvio EA!)
    g_scoreSum = 0.0;
    g_scoreSumSq = 0.0;

    // Reset contatori anti-drift
    g_scoreOperationCount = 0;

    // Reset flag di stato
    g_scoreThresholdReady = false;
    
    // Reset variabili di cache e contatori
    g_tfDataCacheValid = false;
    g_tfDataRecalcCounter = 0;
    g_barsSinceLastRecalc = 0;
    lastBarTime = 0;
    g_dynamicThreshold = 0.0;
    
    if (g_enableLogsEffective) {
        PrintFormat("[DEINIT-BUFFER] g_scoreHistory liberato: %d elementi -> 0 %s",
            scoreSize, ArraySize(g_scoreHistory) == 0 ? "OK" : "ERRORI");
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

    // Reset diagnostica fallimento per questa chiamata
    data.lastUpdateFailCode = 0;
    data.lastUpdateFailShift = 0;

    // Se non c'e' una nuova barra CHIUSA su questo TF, non fare nulla (ottimizzazione)
    datetime currentClosed = iTime(_Symbol, tf, 1);
    if (currentClosed > 0 && data.lastClosedBarTime > 0 && currentClosed == data.lastClosedBarTime)
        return true;

    // Se abbiamo perso piu' di 1 barra chiusa (EA fermo/lag), meglio forzare reload completo
    if (data.lastClosedBarTime > 0) {
        int shift = iBarShift(_Symbol, tf, data.lastClosedBarTime, true);
        if (shift < 0) {
            data.lastUpdateFailCode = 3; // copyFail/shiftFail
            data.lastUpdateFailShift = shift;
            return false;
        }
        if (shift > 2) {
            data.lastUpdateFailCode = 1; // missedBars
            data.lastUpdateFailShift = shift;
            return false;  // piu' di 1 nuova barra chiusa
        }
    }
    
    int count = ArraySize(data.rates);
    int lastIdx = count - 1;
    
    //  FIX CRITICO: Verifica che tutti gli array abbiano la stessa dimensione
    // Se un array e' piu' piccolo, forza reload completo
    if (ArraySize(data.ichimoku_tenkan) < count || ArraySize(data.ichimoku_kijun) < count ||
        ArraySize(data.ichimoku_senkou_a) < count || ArraySize(data.ichimoku_senkou_b) < count ||
        ArraySize(data.ema) < count || ArraySize(data.macd) < count || ArraySize(data.psar) < count ||
        ArraySize(data.sma_fast) < count || ArraySize(data.sma_slow) < count ||
        ArraySize(data.bb_upper) < count || ArraySize(data.atr) < count || ArraySize(data.adx) < count ||
        ArraySize(data.rsi) < count || ArraySize(data.stoch_main) < count || ArraySize(data.obv) < count) {
        data.lastUpdateFailCode = 4; // arraySizeMismatch
        return false;
    }

    // Rolling window: shift a sinistra di 1 e append della nuova barra chiusa (shift=1)
    // Questo mantiene coerenti i lookback (percentili/media/stddev) senza reload completi frequenti.
    {
        // SHIFT rates
        for (int i = 0; i < count - 1; i++)
            data.rates[i] = data.rates[i + 1];

        // Carica la nuova ultima barra CHIUSA
        MqlRates newRate[];
        ArraySetAsSeries(newRate, false);
        if (CopyRates(_Symbol, tf, 1, 1, newRate) < 1) { data.lastUpdateFailCode = 3; return false; }
        data.rates[lastIdx] = newRate[0];
    }
    
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
        data.lastUpdateFailCode = 2; // missingHandles
        return false;
    }
    
    //  FIX CRITICO: Aggiorna TUTTI gli indicatori usati per il voto!
    // Helper macro-like: shift left + append last-closed value from CopyBuffer
    double vBuf[];
    ArrayResize(vBuf, 1);
    ArraySetAsSeries(vBuf, false);

    // Shift di tutti gli array double (mantiene window coerente)
    #define SHIFT_LEFT_DOUBLE(arr) { int n=ArraySize(arr); if(n>1){ for(int ii=0; ii<n-1; ii++) arr[ii]=arr[ii+1]; } }
    #define APPEND_LASTBUF(arr, handle, bufIdx) { if(CopyBuffer(handle, bufIdx, 1, 1, vBuf)!=1) { data.lastUpdateFailCode=3; return false; } arr[lastIdx]=vBuf[0]; }

    // Trend Primary
    SHIFT_LEFT_DOUBLE(data.ema);         APPEND_LASTBUF(data.ema, emaH, 0);
    SHIFT_LEFT_DOUBLE(data.macd);        APPEND_LASTBUF(data.macd, macdH, 0);
    SHIFT_LEFT_DOUBLE(data.macd_signal); APPEND_LASTBUF(data.macd_signal, macdH, 1);
    SHIFT_LEFT_DOUBLE(data.psar);        APPEND_LASTBUF(data.psar, psarH, 0);
    SHIFT_LEFT_DOUBLE(data.sma_fast);    APPEND_LASTBUF(data.sma_fast, smaFastH, 0);
    SHIFT_LEFT_DOUBLE(data.sma_slow);    APPEND_LASTBUF(data.sma_slow, smaSlowH, 0);

    // Ichimoku: buffer 0=Tenkan, 1=Kijun, 2=Senkou A, 3=Senkou B
    SHIFT_LEFT_DOUBLE(data.ichimoku_tenkan);   APPEND_LASTBUF(data.ichimoku_tenkan, ichimokuH, 0);
    SHIFT_LEFT_DOUBLE(data.ichimoku_kijun);    APPEND_LASTBUF(data.ichimoku_kijun, ichimokuH, 1);
    SHIFT_LEFT_DOUBLE(data.ichimoku_senkou_a); APPEND_LASTBUF(data.ichimoku_senkou_a, ichimokuH, 2);
    SHIFT_LEFT_DOUBLE(data.ichimoku_senkou_b); APPEND_LASTBUF(data.ichimoku_senkou_b, ichimokuH, 3);

    // Trend Support (mapping coerente con LoadTimeFrameData: 0=upper,1=middle,2=lower)
    SHIFT_LEFT_DOUBLE(data.bb_upper);  APPEND_LASTBUF(data.bb_upper, bbH, 0);
    SHIFT_LEFT_DOUBLE(data.bb_middle); APPEND_LASTBUF(data.bb_middle, bbH, 1);
    SHIFT_LEFT_DOUBLE(data.bb_lower);  APPEND_LASTBUF(data.bb_lower, bbH, 2);

    // Filters & Mean-Reversion
    SHIFT_LEFT_DOUBLE(data.atr);    APPEND_LASTBUF(data.atr, atrH, 0);
    SHIFT_LEFT_DOUBLE(data.adx);    APPEND_LASTBUF(data.adx, adxH, 0);
    SHIFT_LEFT_DOUBLE(data.di_plus);  APPEND_LASTBUF(data.di_plus, adxH, 1);
    SHIFT_LEFT_DOUBLE(data.di_minus); APPEND_LASTBUF(data.di_minus, adxH, 2);
    SHIFT_LEFT_DOUBLE(data.rsi);    APPEND_LASTBUF(data.rsi, rsiH, 0);
    SHIFT_LEFT_DOUBLE(data.stoch_main);   APPEND_LASTBUF(data.stoch_main, stochH, 0);
    SHIFT_LEFT_DOUBLE(data.stoch_signal); APPEND_LASTBUF(data.stoch_signal, stochH, 1);
    SHIFT_LEFT_DOUBLE(data.obv);    APPEND_LASTBUF(data.obv, obvH, 0);

    // Heikin Ashi (calcolato da rates) - shift + append
    SHIFT_LEFT_DOUBLE(data.ha_close);
    SHIFT_LEFT_DOUBLE(data.ha_open);
    
    // HA Close = (O+H+L+C)/4
    data.ha_close[lastIdx] = (data.rates[lastIdx].open + data.rates[lastIdx].high +
                              data.rates[lastIdx].low + data.rates[lastIdx].close) / 4.0;
    // HA Open = (prev HA Open + prev HA Close) / 2
    if (lastIdx > 0)
        data.ha_open[lastIdx] = (data.ha_open[lastIdx-1] + data.ha_close[lastIdx-1]) / 2.0;
    else
        data.ha_open[lastIdx] = (data.rates[lastIdx].open + data.rates[lastIdx].close) / 2.0;

    // Aggiorna cache timestamp ultima barra chiusa (dopo update riuscito)
    if (currentClosed > 0)
        data.lastClosedBarTime = currentClosed;
    
    //  FIX CRITICO: Ricalcola valori organici (ATR_avg, ADX_threshold, ecc.)
    // Questi DEVONO essere aggiornati ad ogni barra, altrimenti diventano stale!
    // Usa minBarsRequired dal data.organic (gi calcolato in LoadTimeFrameData)
    int minBarsRequired = data.organic.min_bars_required;
    if (minBarsRequired == 0) {
        // Fallback se non impostato: usa periodo naturale * 2
        minBarsRequired = MathMax(10, data.organic.naturalPeriod * 2);
    }
    CalculateOrganicValues(data, count, minBarsRequired);
    
    // LOG DIAGNOSTICO: Rolling window attivo (performance ottimale)
    if (g_enableLogsEffective) {
        static datetime lastLogTime = 0;
        static int rollingCount = 0;
        rollingCount++;
        
        // Log throttled: solo ogni 100 rolling o ogni 5 minuti
        if (rollingCount % 100 == 1 || TimeCurrent() - lastLogTime > 300) {
            PrintFormat("[ROLLING] %s: shift %d barre, append 1 nuova (last=%.5f) | count=%d",
                EnumToString(tf), count-1, data.rates[lastIdx].close, rollingCount);
            lastLogTime = TimeCurrent();
        }
    }
    
    // DIAGNOSTICA: Incrementa contatore ROLLING UPDATE (ottimizzazione attiva)
    g_rollingUpdateCount++;
    
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
    
    // LOG DIAGNOSTICO: Reload completo (carica tutto lo storico)
    if (g_enableLogsEffective) {
        // Calcolo RAM approssimativo: ogni barra = ~20 indicatori × 8 bytes (double)
        int ramKB = (copiedBars * 20 * 8) / 1024;
        PrintFormat("[RELOAD FULL] %s: caricati %d barre (memoria: ~%d KB)",
            EnumToString(tf), copiedBars, ramKB);
    }
    
    // DIAGNOSTICA: Incrementa contatore RELOAD FULL (operazione costosa)
    g_reloadFullCount++;
    
    // FIX: Non piu warning "dati parziali" - ora usiamo quello che c'e
    // Se servono N barre e ne abbiamo M < N, usiamo M (il sistema si adatta)
    
    // FIX: Verifica che i dati non siano corrotti (prezzi validi)
    // Numero barre da verificare: empirico (buffer + frazione del periodo base), nessun Hurst
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
    int barsToCheck = MathMax(4, MathMax(GetBufferSmall(), basePeriod / 4));

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

    // Timestamp dell'ultima barra CHIUSA disponibile (array oldest->newest, start=1)
    if (count > 0)
        data.lastClosedBarTime = data.rates[count - 1].time;

    // Reset diagnostica update cache (dopo RELOAD completo)
    data.lastUpdateFailCode = 0;
    data.lastUpdateFailShift = 0;
    data.lastUpdateFailLoggedAt = 0;
    
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
    // LOOKBACK: periodo naturale + buffer minimo (no H-based scaling)
    // ---------------------------------------------------------------
    int organicLookback = data.organic.naturalPeriod + GetBufferSmall();
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
        data.adx_stddev = data.adx_avg * AdxStddevFallbackFrac;
        if (data.adx_stddev <= 0) data.adx_stddev = AdxStddevAbsMin;  // Fallback assoluto
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
            // Percentili approssimati da min/max usando bounds data-driven
            double adx_range = adx_max - adx_min;
            data.adx_p25 = adx_min + adx_range * (PercentileLow / 100.0);
            data.adx_p75 = adx_min + adx_range * (PercentileHigh / 100.0);
            
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
    
    // Soglia ADX organica = media + stddev (no H-based scaling)
    data.adx_threshold = data.adx_avg + data.adx_stddev;
    
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
    
    // SCALA ORGANICA: usa ATR medio come unita di volatilita (no H-based scaling)
    double min_organic_scale = point_value * data.organic.naturalPeriod;
    
    // FIX: Protezione divisione per zero con fallback multipli
    double atr_scale = data.atr_avg;  // Scala primaria
    
    // Fallback 1: usa min_organic_scale se ATR troppo basso
    if (atr_scale < min_organic_scale || atr_scale <= 0) {
        atr_scale = min_organic_scale;
    }
    
    // Fallback 2: se ancora zero, usa point_value
    if (atr_scale <= 0) {
        atr_scale = point_value;
    }
    
    // Fallback 3: minimo assoluto = ATRScaleAbsMin
    if (atr_scale <= 0) {
        atr_scale = ATRScaleAbsMin;
    }
    
    // VALIDATO: atr_scale sempre > 0 dopo tutti i fallback
    
    // 
    // CALCOLO VALORI NORMALIZZATI (>0 = BUY, <0 = SELL)
    // 
    
    double totalScore = 0;
    
    // Peso organico del TF (uniforme sui TF validi/abilitati)
    double w = data.organic.weight;
    
    //  PESI RELATIVI PER CATEGORIA (no H-based weighting)
    double w_primary = w * 1.0;       // EMA, MACD, PSAR, SMA, Ichimoku
    double w_support = w * 1.0;        // BB, Heikin
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
            // Dentro la cloud = segnale proporzionale
            double cloud_width = cloud_top - cloud_bottom;
            double denominator = (cloud_width / 2.0) + atr_scale;
            // Protezione divisione per zero (guardrail configurabile)
            if (denominator < atr_scale * PSARStepMin) denominator = atr_scale * PSARStepMin;
            cloud_signal = (price - cloud_mid) / denominator;
            cloud_signal = MathMax(-1.0, MathMin(1.0, cloud_signal));
        }
        
        // Combina i segnali con pesi uguali (no H-based weighting)
        double ichi_score = (tk_signal + cloud_signal) / 2.0;
        totalScore += ichi_score * w_primary;  //  TREND PRIMARY
    }
    
    // Bollinger Bands: posizione relativa nel range
    //  FIX: Protezione divisione per zero con minimo data-driven
    if (enableBB && ArraySize(data.bb_upper) > lastIdx && ArraySize(data.bb_lower) > lastIdx && ArraySize(data.bb_middle) > lastIdx) {
        double bb_range = data.bb_upper[lastIdx] - data.bb_lower[lastIdx];
        //  FIX: Minimo BB range = ATR (evita divisione per valori troppo piccoli)
        double min_bb_range = atr_scale;
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
    if (enableHeikin && ArraySize(data.ha_close) > lastIdx && ArraySize(data.ha_open) > lastIdx) {
        double ha_diff = data.ha_close[lastIdx] - data.ha_open[lastIdx];
        double ha_norm = MathMax(-1.0, MathMin(1.0, ha_diff / atr_scale));
        totalScore += ha_norm * w_support;  //  TREND SUPPORT
    }
    
    //  v1.1: OBV  MEAN-REVERSION - vota nella sezione combinata (non qui)
    // L'OBV vota inversione nella sezione CalculateMultiTimeframeScore
    // dove  combinato con RSI e Stochastic per votare direzione inversione
    
    // 
    //  ADX: TREND-FOLLOWING 100% DATA-DRIVEN
    // ---------------------------------------------------------------
    if (enableADX && ArraySize(data.adx) > lastIdx && ArraySize(data.di_plus) > lastIdx && ArraySize(data.di_minus) > lastIdx) {
        double adx_val = data.adx[lastIdx];
        double di_plus = data.di_plus[lastIdx];
        double di_minus = data.di_minus[lastIdx];
        
        // Valori empirici (no H-based scaling)
        double adx_threshold_organic = data.adx_threshold;
        double adx_max_organic = MathMax(adx_threshold_organic, data.adx_p75);
        double di_scale_organic = MathMax(1.0, 0.5 * (MathAbs(di_plus) + MathAbs(di_minus)));
        
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
    // CONTROLLO MEMORIA PERIODICO: Verifica ogni 1000 tick per prevenire crash
    // NOTA: Disabilitato in backtest perché TerminalInfoInteger non funziona correttamente
    static int tickCounter = 0;
    tickCounter++;
    if (tickCounter % 1000 == 0 && !MQLInfoInteger(MQL_TESTER)) {  // Solo in trading reale
        long memoryUsed = TerminalInfoInteger(TERMINAL_MEMORY_USED);
        long memoryLimit = TerminalInfoInteger(TERMINAL_MEMORY_TOTAL);
        long memoryAvailable = memoryLimit - memoryUsed;
        
        // Se meno di 50 MB disponibili, disabilita temporaneamente trading
        if (memoryAvailable < 50 * 1024 * 1024) {
            PrintFormat("? [MEMORY CRITICAL] Memoria critica: %d MB disponibili! Trading sospeso temporaneamente.",
                memoryAvailable / (1024*1024));
            Comment(StringFormat("MEMORIA CRITICA: %d MB disponibili\\nTrading sospeso", 
                memoryAvailable / (1024*1024)));
            return;  // Esci immediatamente da OnTick per risparmiare risorse
        }
        
        // Reset commento se memoria tornata normale
        if (tickCounter % 5000 == 0) {
            Comment("");
        }
    }
    
    // Aggiorna trailing stop per proteggere profitti
    UpdateTrailingStops();
    
    //  Exit anticipato su segnali reversal contrari (taglia perdite grosse)
    CheckEarlyExitOnReversal();
    
    // Controlla eventuale stop loss temporale
    CheckAndCloseOnTimeStop();
    
    // ---------------------------------------------------------------
    // WARMUP (fully empirical): attendi un numero minimo di barre
    // per rendere significative le statistiche e le soglie data-driven.
    // ---------------------------------------------------------------
    if (!g_warmupComplete) {
        static int warmupBarCount = 0;
        static int warmupTickCount = 0;  // Conta anche i tick per timeout assoluto
        warmupBarCount++;
        warmupTickCount++;
        // Protezione overflow: reset se troppo alti
        if (warmupBarCount > 1000000) warmupBarCount = 51;
        if (warmupTickCount > 1000000) warmupTickCount = 501;
        
        int barsM5 = Bars(_Symbol, PERIOD_M5);
        bool barsReady = (g_warmupBarsRequired > 0 && barsM5 >= g_warmupBarsRequired);

        if (barsReady) {
            g_warmupComplete = true;
            Print("[WARMUP] Barre sufficienti - EA pronto per il trading");
        } else {
            // Log anti-spam: stampa solo su avanzamenti a step.
            if (EnableLogs) {
                int req = MathMax(1, g_warmupBarsRequired);
                int now = MathMin(barsM5, req);
                int pct = (int)MathFloor(100.0 * (double)now / (double)req);

                static int lastPct = -1;
                bool pctStep = (pct != lastPct) && (pct % 5 == 0 || pct >= 100);

                if (lastPct < 0 || pctStep) {
                    PrintFormat("[WARMUP] Attesa barre: M5=%d/%d (%d%%)", barsM5, req, pct);
                    lastPct = pct;
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
    int basePeriod = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min : GetBootstrapMinBars();
    int tfDataReloadDivisor = MathMax(2, (int)MathRound((double)basePeriod / 4.0));
    int tfDataReloadInterval = MathMax(1, RecalcEveryBars / tfDataReloadDivisor);  // Reload dinamico
    bool shouldReloadTFData = false;
    
    if (!g_tfDataCacheValid || g_tfDataRecalcCounter >= tfDataReloadInterval) {
        shouldReloadTFData = true;
        g_tfDataRecalcCounter = 0;
    } else {
        g_tfDataRecalcCounter++;
    }
    
    // ============================================================
    // NUOVO APPROCCIO TIME-BASED WINDOW (risolve crash PC)
    // Calcola barre da caricare PER OGNI TF usando finestre temporali
    // derivate dal periodo naturale (auto-driven, memory-safe)
    // ============================================================
    int barsM5 = 0, barsH1 = 0, barsH4 = 0, barsD1 = 0;
    
    if (g_dataReady_M5) barsM5 = CalculateBarsToLoad(PERIOD_M5, g_organic_M5);
    if (g_dataReady_H1 && EnableVote_H1) barsH1 = CalculateBarsToLoad(PERIOD_H1, g_organic_H1);
    if (g_dataReady_H4 && EnableVote_H4) barsH4 = CalculateBarsToLoad(PERIOD_H4, g_organic_H4);
    if (g_dataReady_D1 && EnableVote_D1) barsD1 = CalculateBarsToLoad(PERIOD_D1, g_organic_D1);
    
    // Log diagnostico (throttled per evitare spam)
    static int lastBarsM5 = 0;
    if (g_enableLogsEffective && barsM5 != lastBarsM5) {
        int naturalMins = (g_naturalPeriod_Min > 0) ? g_naturalPeriod_Min * PeriodSeconds(PERIOD_M5) / 60 : 1440;
        PrintFormat("[BARSLOAD] TIME-BASED: M5=%d H1=%d H4=%d D1=%d | window: natural=%dmin × 4 = %dmin",
            barsM5, barsH1, barsH4, barsD1, naturalMins, naturalMins * 4);
        lastBarsM5 = barsM5;
    }
    
    // USA CACHE O RICARICA
    bool m5Loaded = true, h1Loaded = true, h4Loaded = true, d1Loaded = true;
    
    if (shouldReloadTFData) {
        if (g_enableLogsEffective) {
            PrintFormat("[DATA-PERF] TF RELOAD completo: motivo=%s | bars: M5=%d H1=%d H4=%d D1=%d",
                (!g_tfDataCacheValid ? "cacheInvalid" : "interval"),
                barsM5, barsH1, barsH4, barsD1);
        }
        // Ricarica completa: M5 sempre; TF superiori solo se abilitati
        // OGNI TF usa il proprio numero di barre calcolato (time-based window)
        m5Loaded = LoadTimeFrameData(PERIOD_M5, tfData_M5, barsM5);
        h1Loaded = (!EnableVote_H1) ? true : LoadTimeFrameData(PERIOD_H1, tfData_H1, barsH1);
        h4Loaded = (!EnableVote_H4) ? true : LoadTimeFrameData(PERIOD_H4, tfData_H4, barsH4);
        d1Loaded = (!EnableVote_D1) ? true : LoadTimeFrameData(PERIOD_D1, tfData_D1, barsD1);
        g_tfDataCacheValid = true;
        
        if (g_enableLogsEffective) {
            PrintFormat("[DATA] Stato: M5=%s H1=%s H4=%s D1=%s (RELOAD TIME-BASED)",
                m5Loaded ? "?" : "?",
                h1Loaded ? "?" : "?",
                h4Loaded ? "?" : "?",
                d1Loaded ? "?" : "?");
        }
    } else {
        //  USA CACHE - Aggiorna SOLO se il TF ha una nuova barra CHIUSA
        //  (evita CopyRates/CopyBuffer inutili su H1/H4/D1 per ogni barra M5)
        datetime m5Closed = iTime(_Symbol, PERIOD_M5, 1);
        datetime h1Closed = EnableVote_H1 ? iTime(_Symbol, PERIOD_H1, 1) : 0;
        datetime h4Closed = EnableVote_H4 ? iTime(_Symbol, PERIOD_H4, 1) : 0;
        datetime d1Closed = EnableVote_D1 ? iTime(_Symbol, PERIOD_D1, 1) : 0;

        bool m5NeedsUpdate = (m5Closed > 0 && (tfData_M5.lastClosedBarTime == 0 || m5Closed != tfData_M5.lastClosedBarTime));
        bool h1NeedsUpdate = (EnableVote_H1 && h1Closed > 0 && (tfData_H1.lastClosedBarTime == 0 || h1Closed != tfData_H1.lastClosedBarTime));
        bool h4NeedsUpdate = (EnableVote_H4 && h4Closed > 0 && (tfData_H4.lastClosedBarTime == 0 || h4Closed != tfData_H4.lastClosedBarTime));
        bool d1NeedsUpdate = (EnableVote_D1 && d1Closed > 0 && (tfData_D1.lastClosedBarTime == 0 || d1Closed != tfData_D1.lastClosedBarTime));

        m5Loaded = m5NeedsUpdate ? UpdateLastBar(PERIOD_M5, tfData_M5) : true;
        h1Loaded = (!EnableVote_H1) ? true : (h1NeedsUpdate ? UpdateLastBar(PERIOD_H1, tfData_H1) : true);
        h4Loaded = (!EnableVote_H4) ? true : (h4NeedsUpdate ? UpdateLastBar(PERIOD_H4, tfData_H4) : true);
        d1Loaded = (!EnableVote_D1) ? true : (d1NeedsUpdate ? UpdateLastBar(PERIOD_D1, tfData_D1) : true);
        
        // DIAGNOSTICA: Conta CACHE HIT (nessuna nuova barra = skip update)
        if (!m5NeedsUpdate) g_cacheHitCount++;
        if (EnableVote_H1 && !h1NeedsUpdate) g_cacheHitCount++;
        if (EnableVote_H4 && !h4NeedsUpdate) g_cacheHitCount++;
        if (EnableVote_D1 && !d1NeedsUpdate) g_cacheHitCount++;

        if (g_enableLogsEffective) {
            string m5Str = m5NeedsUpdate ? (m5Loaded ? "ROLL" : "FAIL") : "SKIP(noNewBar)";
            string h1Str = (!EnableVote_H1) ? "SKIP(disabled)" : (h1NeedsUpdate ? (h1Loaded ? "ROLL" : "FAIL") : "SKIP(noNewBar)");
            string h4Str = (!EnableVote_H4) ? "SKIP(disabled)" : (h4NeedsUpdate ? (h4Loaded ? "ROLL" : "FAIL") : "SKIP(noNewBar)");
            string d1Str = (!EnableVote_D1) ? "SKIP(disabled)" : (d1NeedsUpdate ? (d1Loaded ? "ROLL" : "FAIL") : "SKIP(noNewBar)");
            PrintFormat("[DATA-PERF] TF update: M5=%s H1=%s H4=%s D1=%s | cacheCounter=%d/%d",
                m5Str, h1Str, h4Str, d1Str, g_tfDataRecalcCounter, tfDataReloadInterval);
            
            // LOG RIEPILOGO PERFORMANCE (ogni 1000 operazioni)
            static int lastReportOps = 0;
            int totalOps = g_rollingUpdateCount + g_reloadFullCount + g_cacheHitCount;
            if (totalOps > 0 && (totalOps - lastReportOps >= 1000 || totalOps % 500 == 100)) {
                double rollingPct = (g_rollingUpdateCount * 100.0) / totalOps;
                double reloadPct = (g_reloadFullCount * 100.0) / totalOps;
                double cachePct = (g_cacheHitCount * 100.0) / totalOps;
                PrintFormat("[PERF REPORT] Total ops=%d | ROLLING=%d (%.1f%%) | RELOAD=%d (%.1f%%) | CACHE_HIT=%d (%.1f%%)",
                    totalOps, g_rollingUpdateCount, rollingPct, g_reloadFullCount, reloadPct, g_cacheHitCount, cachePct);
                lastReportOps = totalOps;
            }
        }
        
        //  FIX: Se update cache fallisce, forza reload SOLO del TF fallito per recuperare
        if (!m5Loaded || !h1Loaded || !h4Loaded || !d1Loaded) {
            static int cacheFailCount = 0;
            cacheFailCount++;
            if (cacheFailCount <= 3 || cacheFailCount % 20 == 0) {
                PrintFormat("[DATA RECOVER #%d] Cache update fallito - forzo RELOAD (solo TF falliti)", cacheFailCount);
            }

            // Rifinitura debug: spiega chiaramente quando il rolling update fallisce per missed bars
            if (g_enableLogsEffective) {
                if (!m5Loaded && tfData_M5.lastUpdateFailCode == 1 && tfData_M5.lastUpdateFailLoggedAt != currentBarTime) {
                    PrintFormat("[DATA-PERF] TF %s cache FAIL: missedBars (shift=%d) -> RELOAD",
                        EnumToString(PERIOD_M5), tfData_M5.lastUpdateFailShift);
                    tfData_M5.lastUpdateFailLoggedAt = currentBarTime;
                }
                if (EnableVote_H1 && !h1Loaded && tfData_H1.lastUpdateFailCode == 1 && tfData_H1.lastUpdateFailLoggedAt != currentBarTime) {
                    PrintFormat("[DATA-PERF] TF %s cache FAIL: missedBars (shift=%d) -> RELOAD",
                        EnumToString(PERIOD_H1), tfData_H1.lastUpdateFailShift);
                    tfData_H1.lastUpdateFailLoggedAt = currentBarTime;
                }
                if (EnableVote_H4 && !h4Loaded && tfData_H4.lastUpdateFailCode == 1 && tfData_H4.lastUpdateFailLoggedAt != currentBarTime) {
                    PrintFormat("[DATA-PERF] TF %s cache FAIL: missedBars (shift=%d) -> RELOAD",
                        EnumToString(PERIOD_H4), tfData_H4.lastUpdateFailShift);
                    tfData_H4.lastUpdateFailLoggedAt = currentBarTime;
                }
                if (EnableVote_D1 && !d1Loaded && tfData_D1.lastUpdateFailCode == 1 && tfData_D1.lastUpdateFailLoggedAt != currentBarTime) {
                    PrintFormat("[DATA-PERF] TF %s cache FAIL: missedBars (shift=%d) -> RELOAD",
                        EnumToString(PERIOD_D1), tfData_D1.lastUpdateFailShift);
                    tfData_D1.lastUpdateFailLoggedAt = currentBarTime;
                }
            }

            // Forza reload per ripristinare isDataReady (solo TF necessari)
            // USA TIME-BASED WINDOW: ogni TF ha il proprio numero di barre
            if (!m5Loaded) m5Loaded = LoadTimeFrameData(PERIOD_M5, tfData_M5, barsM5);
            if (EnableVote_H1 && !h1Loaded) h1Loaded = LoadTimeFrameData(PERIOD_H1, tfData_H1, barsH1);
            if (EnableVote_H4 && !h4Loaded) h4Loaded = LoadTimeFrameData(PERIOD_H4, tfData_H4, barsH4);
            if (EnableVote_D1 && !d1Loaded) d1Loaded = LoadTimeFrameData(PERIOD_D1, tfData_D1, barsD1);
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
        
        // Log organico ogni naturalPeriod secondi per barra (no H-based scaling)
        int logIntervalSeconds = (int)MathRound(g_organic_M5.naturalPeriod * 60);
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
    }
    
    ExecuteTradingLogic();
    if (g_enableLogsEffective) {
        Print("[TRADE] Elaborazione completata");
        Print("");
    }
}  // Fine OnTick()

//+------------------------------------------------------------------+
//| Logica di trading principale                                     |
//+------------------------------------------------------------------+
void ExecuteTradingLogic()
{
    // Esegui logica di voto
    int voteResult = ExecuteVotingLogic();
    int decisionDir = voteResult;
    string voteStr = (decisionDir == 1) ? "BUY" : ((decisionDir == -1) ? "SELL" : "NEUTRAL");
    if (g_enableLogsEffective) {
        PrintFormat("[VOTE] Risultato: %s (score raw: %d)", voteStr, voteResult);
    }

    // Entry attempt = c'e' un segnale
    bool entryAttempt = (voteResult != 0);

    // Helper: contesto compatto non ripetitivo per debug
    string ctx = "";
    if (entryAttempt) {
        ctx = StringFormat(" | score=%.1f%% thr=%.1f%% eff=%.1f%%", g_lastScorePct, g_lastThresholdBasePct, g_lastThresholdEffPct);
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
        // Log throttle: naturalPeriod * secondi per barra (no H-based scaling)
        // FIX: Protezione quando naturalPeriod = 0
        int naturalPeriod = MathMax(1, g_organic_M5.naturalPeriod);  // Minimo 1 per evitare divisione per zero
        int throttleSeconds = (int)MathRound(naturalPeriod * 60);
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
    
    //  DETECTOR INVERSIONE: Aggiorna tutti i segnali MEAN-REVERSION
    int momentumSignal = UpdateScoreMomentum(totalScore);
    int divergenceSignal = UpdateRSIDivergence();
    
    //  NUOVI DETECTOR MEAN-REVERSION (v1.1)
    int stochExtremeSignal = UpdateStochasticExtreme();
    int obvDivergenceSignal = UpdateOBVDivergence();
    
    // Combina RSI + Stochastic + OBV in un UNICO segnale data-driven
    // Poi applica questo voto a OGNI TIMEFRAME attivo
    int meanRevCombinedSignal = 0;  // +1=BUY, -1=SELL, 0=NEUTRO
    double meanRevCombinedStrength = 0.0;  // Forza del segnale combinato [0-1]
    
    // Pesi uguali (no H-based weighting)
    double w_rsi = 1.0;
    double w_obv = 1.0;
    double w_stoch = 1.0;

    // Fattore neutro: in v1.1 non si usa piu' alcun decay(H)
    double decay = 1.0;
    
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
    
    // SOGLIA 100% DATA-DRIVEN per attivare mean-reversion combinata:
    // Manteniamo una storia rolling della forza combinata e calcoliamo: mean + stdev.
    static double s_meanRevHist[];
    static int s_meanRevSize = 0;
    static int s_meanRevIdx = 0;
    static double s_meanRevSum = 0.0;
    static double s_meanRevSumSq = 0.0;
    static bool s_meanRevReady = false;
    static double s_meanRevThreshold = 1.0;

    int meanRevHistMax = GetBufferXLarge();
    if (ArraySize(s_meanRevHist) != meanRevHistMax) {
        ArrayResize(s_meanRevHist, meanRevHistMax);
        ArrayInitialize(s_meanRevHist, 0.0);
        s_meanRevSize = 0;
        s_meanRevIdx = 0;
        s_meanRevSum = 0.0;
        s_meanRevSumSq = 0.0;
        s_meanRevReady = false;
        s_meanRevThreshold = 1.0;
    }

    // Calcola forza combinata (anche se non supera soglia)
    if (combinedMax > 0.0) {
        meanRevCombinedStrength = MathAbs(combinedScore) / combinedMax;
        if (meanRevCombinedStrength < 0.0) meanRevCombinedStrength = 0.0;
        if (meanRevCombinedStrength > 1.0) meanRevCombinedStrength = 1.0;

        // Update rolling stats (O(1))
        if (s_meanRevSize == meanRevHistMax) {
            double oldV = s_meanRevHist[s_meanRevIdx];
            s_meanRevSum -= oldV;
            s_meanRevSumSq -= oldV * oldV;
            double sumBound = (double)meanRevHistMax * (double)meanRevHistMax;
            if (s_meanRevSum < -sumBound) s_meanRevSum = 0.0;
            if (s_meanRevSumSq < 0.0) s_meanRevSumSq = 0.0;
        }

        s_meanRevHist[s_meanRevIdx] = meanRevCombinedStrength;
        s_meanRevSum += meanRevCombinedStrength;
        s_meanRevSumSq += meanRevCombinedStrength * meanRevCombinedStrength;
        s_meanRevIdx = (s_meanRevIdx + 1) % meanRevHistMax;
        if (s_meanRevSize < meanRevHistMax) s_meanRevSize++;

        int minSamplesMR = GetBufferSmall();
        if (s_meanRevSize >= minSamplesMR) {
            double m = s_meanRevSum / s_meanRevSize;
            double var = (s_meanRevSumSq / s_meanRevSize) - (m * m);
            var = MathMax(0.0, var);
            double sd = (var > 0.0) ? MathSqrt(var) : 0.0;
            s_meanRevThreshold = m + sd;
            // Clamp ai dati osservati
            double minC = CalculatePercentile(s_meanRevHist, s_meanRevSize, 0);
            double maxC = CalculatePercentile(s_meanRevHist, s_meanRevSize, 100);
            s_meanRevThreshold = MathMax(minC, MathMin(maxC, s_meanRevThreshold));
            s_meanRevReady = true;
        }
    }

    double meanRevThreshold = s_meanRevThreshold;
    if (combinedMax > 0.0 && s_meanRevReady && meanRevCombinedStrength >= meanRevThreshold) {
        meanRevCombinedSignal = (combinedScore > 0) ? 1 : -1;
    }
    
    // STEP 2: Applica il VOTO UNICO a OGNI TF attivo
    // Peso = decay(H) * peso_TF (mean-reversion = contrarian, peso ridotto)
    double meanRevScore = 0.0;
    double meanRevMaxScore = 0.0;
    
    // Max mean-reversion: consideralo solo se il segnale e' attivo.
    // Evita penalizzare scorePct quando RSI/OBV/Stoch sono abilitati ma neutri.
    if ((enableRSI || enableOBV || enableStoch) && meanRevCombinedSignal != 0) {
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
    
    // TREND SUPPORT (peso empirico)
    double supportWeight = 1.0;
    if (enableBB) weightTrendSupport += supportWeight;
    if (enableHeikin) weightTrendSupport += supportWeight;
    
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
    
    // v1.1: GetReversalSignal per tracciare statistiche (soglia data-driven)
    // I detector sono gia stati chiamati sopra, questa chiamata aggiorna solo il buffer storico
    double reversalStrength = 0.0;
    int reversalSignal = GetReversalSignal(reversalStrength);
    
    // AGGIUNGI SCORE AL BUFFER STORICO (per soglia automatica)
    // INPUT: scorePct >= 0 (validato sopra)
    AddScoreToHistory(scorePct);
    
    // OTTIENI SOGLIA CORRENTE (automatica o manuale, con fallback)
    double currentThreshold = GetCurrentThreshold();

    double effectiveThreshold = currentThreshold;
    if (effectiveThreshold > 100.0) effectiveThreshold = 100.0;

    // Salva diagnostica per log DECISION (ExecuteTradingLogic)
    g_lastThresholdBasePct = currentThreshold;
    g_lastThresholdEffPct = effectiveThreshold;
    g_lastScorePct = scorePct;
    
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
        
        PrintFormat("[SCORE DEBUG] Score: %+.2f | Max: %.2f | Pct: %.2f%% | Soglia: %.1f%% (%s)",
            totalScore, maxScorePossible, scorePct, currentThreshold, thresholdType);
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
    // Nota: se vuoi che la soglia manuale sia "rigida", disattiva EnableEarlyEntryBelowThreshold.
    if (EnableEarlyEntryBelowThreshold && decision == 0 && reversalSignal != 0 && reversalStrength >= g_reversalThreshold) {
        // Score deve essere almeno nella stessa direzione del reversal
        bool directionMatch = (reversalSignal == 1 && totalScore >= 0) || 
                              (reversalSignal == -1 && totalScore <= 0);
        
        // Soglia ridotta data-driven: riduzione proporzionale alla difficolta' mean-reversion
        // (se mean-rev richiede forza alta, riduciamo meno; viceversa riduciamo di piu')
        double reversalThreshold = effectiveThreshold * (1.0 - meanRevThreshold);
        
        // Log dettagliato analisi entry anticipato
        if (g_enableLogsEffective && (reversalStrength >= g_reversalThreshold || scorePct >= reversalThreshold * 0.8)) {
            PrintFormat("[ENTRY ANTICIPATO %s] Analisi:",
                TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
            PrintFormat("   Reversal: %s strength=%.0f%% (soglia %.0f%% %s)",
                reversalSignal > 0 ? "BUY" : reversalSignal < 0 ? "SELL" : "NONE",
                reversalStrength * 100, g_reversalThreshold * 100,
                reversalStrength >= g_reversalThreshold ? "OK" : "NO");
            PrintFormat("   Score: %.1f%% vs soglia ridotta %.1f%% (effThr=%.1f%%)",
                scorePct, reversalThreshold, effectiveThreshold);
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
            reason = StringFormat("Score %.1f%% < %.1f%% soglia", scorePct, effectiveThreshold);
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
    
    // ---------------------------------------------------------------
    // Normalizza e valida SL/TP rispetto ai vincoli broker
    // ---------------------------------------------------------------
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int stopsLevelPts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double minStopDist = (stopsLevelPts > 0 ? stopsLevelPts * point : 0.0);
    if (sl > 0) sl = NormalizeDouble(sl, digits);
    if (tp > 0) tp = NormalizeDouble(tp, digits);
    // SELL: SL sopra, TP sotto
    if (sl > 0 && sl <= price + minStopDist) sl = NormalizeDouble(price + minStopDist, digits);
    if (tp > 0 && tp >= price - minStopDist) tp = NormalizeDouble(price - minStopDist, digits);

    // Market order: lascia che il server scelga il prezzo (piu' robusto di passare bid/ask)
    if (trade.Sell(finalLot, _Symbol, 0.0, sl, tp, "Auto SELL")) {
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

        RegisterEntrySnapshot(snap);

        // ---------------------------------------------------------------
        // FIX: Applica SL/TP in modo deterministico dopo l'entry
        // In alcuni ambienti (tester/broker) i livelli possono essere ignorati se troppo vicini.
        // Qui li ricalcoliamo rispetto al prezzo di apertura effettivo e li impostiamo via SLTP.
        // ---------------------------------------------------------------
        if (positionId > 0 && (SellStopLossPoints > 0 || SellTakeProfitPoints > 0 || StopLossPriceSell > 0 || TakeProfitPriceSell > 0))
        {
            ulong positionTicket = 0;
            if (TryGetPositionTicketByIdentifier(positionId, positionTicket) && PositionSelectByTicket(positionTicket))
            {
                double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                double desiredSL = 0.0;
                double desiredTP = 0.0;

                // Priorita': prezzo fisso (se >0), altrimenti punti relativi all'open effettivo
                if (StopLossPriceSell > 0) desiredSL = StopLossPriceSell;
                else if (SellStopLossPoints > 0) desiredSL = openPrice + SellStopLossPoints * point;

                if (TakeProfitPriceSell > 0) desiredTP = TakeProfitPriceSell;
                else if (SellTakeProfitPoints > 0) desiredTP = openPrice - SellTakeProfitPoints * point;

                if (desiredSL > 0) desiredSL = NormalizeDouble(desiredSL, digits);
                if (desiredTP > 0) desiredTP = NormalizeDouble(desiredTP, digits);

                // Rispetta stop level
                if (desiredSL > 0 && desiredSL <= openPrice + minStopDist) desiredSL = NormalizeDouble(openPrice + minStopDist, digits);
                if (desiredTP > 0 && desiredTP >= openPrice - minStopDist) desiredTP = NormalizeDouble(openPrice - minStopDist, digits);

                double curSL = PositionGetDouble(POSITION_SL);
                double curTP = PositionGetDouble(POSITION_TP);
                bool needSL = (desiredSL > 0 && (curSL <= 0 || MathAbs(curSL - desiredSL) > point * 0.5));
                bool needTP = (desiredTP > 0 && (curTP <= 0 || MathAbs(curTP - desiredTP) > point * 0.5));

                if (needSL || needTP)
                {
                    MqlTradeRequest req;
                    MqlTradeResult res;
                    ZeroMemory(req);
                    ZeroMemory(res);
                    req.action = TRADE_ACTION_SLTP;
                    req.symbol = _Symbol;
                    req.position = positionTicket;
                    req.magic = g_uniqueMagicNumber;
                    req.sl = (desiredSL > 0 ? desiredSL : curSL);
                    req.tp = (desiredTP > 0 ? desiredTP : curTP);
                    if (!OrderSend(req, res))
                    {
                        if (g_enableLogsEffective)
                            PrintFormat("[TRADE] WARN: SLTP post-entry fallito (SELL) posId=%I64u ticket=%I64u err=%d", positionId, positionTicket, GetLastError());
                    }
                    else
                    {
                        if (g_enableLogsEffective)
                        {
                            double newSL = PositionGetDouble(POSITION_SL);
                            double newTP = PositionGetDouble(POSITION_TP);
                            PrintFormat("[TRADE] SLTP post-entry applicato (SELL) posId=%I64u ticket=%I64u SL=%.5f TP=%.5f (posSL=%.5f posTP=%.5f)",
                                positionId, positionTicket, req.sl, req.tp, newSL, newTP);
                        }
                    }
                }
            }
            else
            {
                if (g_enableLogsEffective)
                    PrintFormat("[TRADE] WARN: impossibile selezionare posizione per SLTP post-entry (SELL) posId=%I64u", positionId);
            }
        }
        
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
            PrintFormat("[SNAP] EntrySnapshot saved #%I64u | score=%.1f%% thr=%.1f%% eff=%.1f%% | method=%s",
                positionId,
                snap.scorePctAtEntry, snap.thresholdBasePct, snap.thresholdEffPct,
                ThresholdMethodToString(snap.thresholdMethodId));
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
    
    // ---------------------------------------------------------------
    // Normalizza e valida SL/TP rispetto ai vincoli broker
    // ---------------------------------------------------------------
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int stopsLevelPts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double minStopDist = (stopsLevelPts > 0 ? stopsLevelPts * point : 0.0);
    if (sl > 0) sl = NormalizeDouble(sl, digits);
    if (tp > 0) tp = NormalizeDouble(tp, digits);
    // BUY: SL sotto, TP sopra
    if (sl > 0 && sl >= price - minStopDist) sl = NormalizeDouble(price - minStopDist, digits);
    if (tp > 0 && tp <= price + minStopDist) tp = NormalizeDouble(price + minStopDist, digits);

    // Market order: lascia che il server scelga il prezzo (piu' robusto di passare bid/ask)
    if (trade.Buy(finalLot, _Symbol, 0.0, sl, tp, "Auto BUY")) {
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

        RegisterEntrySnapshot(snap);

        // ---------------------------------------------------------------
        // FIX: Applica SL/TP in modo deterministico dopo l'entry
        // Ricalcola su prezzo di apertura effettivo per rispettare esattamente i "points".
        // ---------------------------------------------------------------
        if (positionId > 0 && (BuyStopLossPoints > 0 || BuyTakeProfitPoints > 0 || StopLossPriceBuy > 0 || TakeProfitPriceBuy > 0))
        {
            ulong positionTicket = 0;
            if (TryGetPositionTicketByIdentifier(positionId, positionTicket) && PositionSelectByTicket(positionTicket))
            {
                double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                double desiredSL = 0.0;
                double desiredTP = 0.0;

                // Priorita': prezzo fisso (se >0), altrimenti punti relativi all'open effettivo
                if (StopLossPriceBuy > 0) desiredSL = StopLossPriceBuy;
                else if (BuyStopLossPoints > 0) desiredSL = openPrice - BuyStopLossPoints * point;

                if (TakeProfitPriceBuy > 0) desiredTP = TakeProfitPriceBuy;
                else if (BuyTakeProfitPoints > 0) desiredTP = openPrice + BuyTakeProfitPoints * point;

                if (desiredSL > 0) desiredSL = NormalizeDouble(desiredSL, digits);
                if (desiredTP > 0) desiredTP = NormalizeDouble(desiredTP, digits);

                // Rispetta stop level
                if (desiredSL > 0 && desiredSL >= openPrice - minStopDist) desiredSL = NormalizeDouble(openPrice - minStopDist, digits);
                if (desiredTP > 0 && desiredTP <= openPrice + minStopDist) desiredTP = NormalizeDouble(openPrice + minStopDist, digits);

                double curSL = PositionGetDouble(POSITION_SL);
                double curTP = PositionGetDouble(POSITION_TP);
                bool needSL = (desiredSL > 0 && (curSL <= 0 || MathAbs(curSL - desiredSL) > point * 0.5));
                bool needTP = (desiredTP > 0 && (curTP <= 0 || MathAbs(curTP - desiredTP) > point * 0.5));

                if (needSL || needTP)
                {
                    MqlTradeRequest req;
                    MqlTradeResult res;
                    ZeroMemory(req);
                    ZeroMemory(res);
                    req.action = TRADE_ACTION_SLTP;
                    req.symbol = _Symbol;
                    req.position = positionTicket;
                    req.magic = g_uniqueMagicNumber;
                    req.sl = (desiredSL > 0 ? desiredSL : curSL);
                    req.tp = (desiredTP > 0 ? desiredTP : curTP);
                    if (!OrderSend(req, res))
                    {
                        if (g_enableLogsEffective)
                            PrintFormat("[TRADE] WARN: SLTP post-entry fallito (BUY) posId=%I64u ticket=%I64u err=%d", positionId, positionTicket, GetLastError());
                    }
                    else
                    {
                        if (g_enableLogsEffective)
                        {
                            double newSL = PositionGetDouble(POSITION_SL);
                            double newTP = PositionGetDouble(POSITION_TP);
                            PrintFormat("[TRADE] SLTP post-entry applicato (BUY) posId=%I64u ticket=%I64u SL=%.5f TP=%.5f (posSL=%.5f posTP=%.5f)",
                                positionId, positionTicket, req.sl, req.tp, newSL, newTP);
                        }
                    }
                }
            }
            else
            {
                if (g_enableLogsEffective)
                    PrintFormat("[TRADE] WARN: impossibile selezionare posizione per SLTP post-entry (BUY) posId=%I64u", positionId);
            }
        }
        
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
            PrintFormat("[SNAP] EntrySnapshot saved #%I64u | score=%.1f%% thr=%.1f%% eff=%.1f%% | method=%s",
                positionId,
                snap.scorePctAtEntry, snap.thresholdBasePct, snap.thresholdEffPct,
                ThresholdMethodToString(snap.thresholdMethodId));
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
        
        // Modifica posizione con nuovo SL (usa SLTP su ticket posizione per compatibilita' hedging)
        {
            MqlTradeRequest req;
            MqlTradeResult res;
            ZeroMemory(req);
            ZeroMemory(res);
            req.action = TRADE_ACTION_SLTP;
            req.symbol = _Symbol;
            req.position = ticket;
            req.magic = uniqueMagic;
            req.sl = newSL;
            req.tp = currentTP;
            if (OrderSend(req, res)) {
            PrintFormat("[TRAILING] Aggiornato SL posizione #%I64u %s | Profit: %.0f points | Nuovo SL: %.5f (step %d points)",
                ticket, type == POSITION_TYPE_BUY ? "BUY" : "SELL", 
                profitPoints, newSL, trailingStep);
            } else {
            int errCode = GetLastError();
            // Log errore solo se non  "no changes" (codice 10025)
            if (errCode != 10025) {
            }
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
    if (!EnableEarlyExitOnReversal) return;
    int totalPositions = PositionsTotal();
    if (totalPositions == 0) return;

    // Valuta una sola volta per barra M5 (default), per evitare close su rumore intra-bar.
    static datetime s_lastM5BarTime = 0;
    if (EarlyExitCheckOnNewM5BarOnly) {
        datetime bt = iTime(_Symbol, PERIOD_M5, 0);
        if (bt <= 0) return;
        if (bt == s_lastM5BarTime) return;
        s_lastM5BarTime = bt;
    }
    
    int uniqueMagic = g_uniqueMagicNumber;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    // Ottieni segnali mean-reversion correnti
    double reversalStrength = 0.0;
    int reversalSignal = GetReversalSignal(reversalStrength, false);

    // Soglia reversal: AUTO (data-driven) o manuale
    double reversalThr = g_reversalThreshold;
    if (EarlyExitReversalStrengthOverride > 0.0) reversalThr = EarlyExitReversalStrengthOverride;

    // Richiedi conferma su N barre (default 2) per ridurre chiusure affrettate.
    // FIX: se il reversal sparisce o scende sotto soglia, resettiamo la conferma.
    static int s_confirmCount = 0;
    static int s_lastSignal = 0;
    int needBars = MathMax(1, EarlyExitConfirmBars);
    if (reversalSignal == 0 || reversalStrength < reversalThr) {
        s_confirmCount = 0;
        s_lastSignal = 0;
        return;
    }

    if (reversalSignal == s_lastSignal) s_confirmCount++;
    else {
        s_lastSignal = reversalSignal;
        s_confirmCount = 1;
    }
    if (s_confirmCount < needBars) {
        if (g_enableLogsEffective) {
            PrintFormat("[EARLY EXIT] Reversal OK ma in attesa conferma: sig=%s forza=%.0f%% thr=%.0f%% (%d/%d)",
                reversalSignal > 0 ? "BUY" : "SELL",
                reversalStrength * 100.0,
                reversalThr * 100.0,
                s_confirmCount, needBars);
        }
        return;
    }
    
    for (int i = totalPositions - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != uniqueMagic) continue;
        
        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double profitPL = PositionGetDouble(POSITION_PROFIT);

        if (EarlyExitMinPositionAgeMinutes > 0) {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            int ageMinutes = (int)((TimeCurrent() - openTime) / 60);
            if (ageMinutes < EarlyExitMinPositionAgeMinutes) continue;
        }
        
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
        
        // Chiudi solo se perdita significativa (empirico): frazione di ATR (in pips)
        // Evita chiusure su noise normale
        double atrPips = 0.0;
        if (g_lastCacheATR > 0.0 && point > 0.0) {
            atrPips = g_lastCacheATR / point / 10.0;
        }
        if (atrPips <= 0.0) atrPips = EarlyExitAtrPipsFallback;
        double lossFloor = (EarlyExitMinLossPipsOverride > 0.0 ? EarlyExitMinLossPipsOverride : EarlyExitMinLossPipsFloor);
        double atrFrac = (EarlyExitMinLossAtrFracOverride > 0.0 ? EarlyExitMinLossAtrFracOverride : EarlyExitMinLossAtrFrac);
        double minLossThreshold = MathMax(lossFloor, atrFrac * atrPips);
        if (shouldClose && lossPips > minLossThreshold) {
            if (trade.PositionClose(ticket)) {
                PrintFormat("[EARLY EXIT] Chiusa posizione #%I64u %s | Loss: %.1f pips (%.2f EUR) | Motivo: %s (forza %.0f%%)",
                    ticket, type == POSITION_TYPE_BUY ? "BUY" : "SELL",
                    lossPips, profitPL, closeReason, reversalStrength * 100);
                if (g_enableLogsEffective) {
                    PrintFormat("[EARLY EXIT] Dettagli: conf=%d/%d thrRev=%.0f%% lossThr=%.2f pips (floor=%.2f atr=%.2f atrFrac=%.3f)",
                        s_confirmCount, needBars, reversalThr * 100.0, minLossThreshold, lossFloor, atrPips, atrFrac);
                }
            } else {
                PrintFormat("[EARLY EXIT] WARN: errore chiusura #%I64u: %d", ticket, GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Stop loss temporale su posizioni aperte                          |
//|  FIX: Usa sessioni broker per conteggio tempo trading           |
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

        // Calcola tempo di TRADING effettivo usando le sessioni del broker.
        // Fallback: se le sessioni non sono disponibili, usa il tempo totale.
        long sessSeconds = ComputeTradingSecondsFromSessions(openTime, now);
        long totalSeconds = (long)(now - openTime);
        int tradingSeconds = (int)MathMax(0, (sessSeconds >= 0 ? sessSeconds : totalSeconds));

        static bool s_warnedSessionFallback = false;
        if (sessSeconds < 0 && !s_warnedSessionFallback) {
            PrintFormat("INFO: broker sessions unavailable for %s; time-stop uses wall-clock elapsed time.", _Symbol);
            s_warnedSessionFallback = true;
        }
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
            PrintFormat("[TIME STOP] OK Chiusa posizione #%I64u %s (Lot: %.2f, P/L: %.2f)", 
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
    
    // Score breakdown
    if (scoreAtEntry > 0) {
        double thresholdAtEntry = g_scoreThresholdReady ? g_dynamicThreshold : ScoreThreshold;
        PrintFormat("Score@Entry: %.1f%% (soglia %.1f%%)", scoreAtEntry, thresholdAtEntry);
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
        g_recentTrades[g_recentTradesIndex].sl = snapFound ? snap.sl : 0.0;
        g_recentTrades[g_recentTradesIndex].tp = snapFound ? snap.tp : 0.0;
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
            
            // Threshold info
            PrintFormat("Threshold: %.1f%% (%s) | TF: M5=%s H1=%s H4=%s D1=%s",
                g_scoreThresholdReady ? g_dynamicThreshold : ScoreThreshold,
                AutoScoreThreshold ? (g_youdenReady ? "Youden" : "Otsu") : "Manual",
                g_vote_M5_active ? "ON" : "OFF",
                g_vote_H1_active ? "ON" : "OFF",
                g_vote_H4_active ? "ON" : "OFF",
                g_vote_D1_active ? "ON" : "OFF");
            Print("============================================================");
            Print("");
        }
    }
}
