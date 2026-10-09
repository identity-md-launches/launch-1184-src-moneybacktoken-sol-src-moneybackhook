// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================================================= //
//  Minimal Uniswap v4 types and interfaces.                                                     //
//  The launch build vendors no libraries, so the exact ABI shapes of v4-core are restated here. //
//  Every struct, user-defined value type and selector below is byte-for-byte compatible with    //
//  v4-core (PoolKey, SwapParams, BalanceDelta, BeforeSwapDelta, IHooks, IPoolManager).          //
// ============================================================================================= //

/// @dev Address of an ERC20 token, or address(0) for native ETH. Same as v4-core `Currency`.
type Currency is address;

/// @dev keccak256(abi.encode(PoolKey)). Same as v4-core `PoolId`.
type PoolId is bytes32;

/// @dev Packed (int128 amount0 << 128 | int128 amount1). Same as v4-core `BalanceDelta`.
type BalanceDelta is int256;

/// @dev Packed (int128 specified << 128 | int128 unspecified). Same as v4-core `BeforeSwapDelta`.
type BeforeSwapDelta is int256;

/// @dev Same field order and types as v4-core `PoolKey` (hooks is `IHooks` there; an address here).
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev Same as v4-core `SwapParams`: amountSpecified < 0 is exact input, > 0 is exact output.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @dev The PoolManager surface the hook (and anything built on it) needs.
interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta swapDelta);
    function sync(Currency currency) external;
    function settle() external payable returns (uint256 paid);
    function take(Currency currency, address to, uint256 amount) external;
    function mint(address to, uint256 id, uint256 amount) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function balanceOf(address owner, uint256 id) external view returns (uint256 amount);
}

/// @dev Same as v4-core `IUnlockCallback`.
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Same selectors as v4-core `IHooks` for the callbacks this hook implements.
interface IHooks {
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24);
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128);
}

/// @dev Hook address flag bits, identical to v4-core `Hooks`.
library HookFlags {
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;
    uint160 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 internal constant AFTER_DONATE_FLAG = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0;

    /// @dev The exact flag set of MoneyBackHook: beforeInitialize | beforeSwap | afterSwap
    ///      | beforeSwapReturnDelta | afterSwapReturnDelta = 0x20CC.
    uint160 internal constant MONEYBACK_FLAGS = BEFORE_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG
        | BEFORE_SWAP_RETURNS_DELTA_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG;

    error HookAddressNotValid(address hooks);

    /// @dev Same check as v4-core `Hooks.validateHookPermissions`: the low 14 address bits must
    ///      equal the permission set exactly (no extra, no missing flag).
    function validateHookPermissions(address self, uint160 expectedFlags) internal pure {
        if (uint160(self) & ALL_HOOK_MASK != expectedFlags) revert HookAddressNotValid(self);
    }
}

/// @dev Packing helpers identical to v4-core `BalanceDeltaLibrary` / `BeforeSwapDeltaLibrary`.
library DeltaLib {
    function amount0(BalanceDelta d) internal pure returns (int128 a) {
        assembly ("memory-safe") {
            a := sar(128, d)
        }
    }

    function amount1(BalanceDelta d) internal pure returns (int128 a) {
        assembly ("memory-safe") {
            a := signextend(15, d)
        }
    }

    function toBeforeSwapDelta(int128 specified, int128 unspecified) internal pure returns (BeforeSwapDelta d) {
        assembly ("memory-safe") {
            d := or(shl(128, specified), and(sub(shl(128, 1), 1), unspecified))
        }
    }
}

// ============================================================================================= //
//                                        MoneyBackHook                                          //
// ============================================================================================= //

/// @title MoneyBackHook: 4.25% IMD fee (+ decaying sell surcharge) for the MONEYBACK/IMD v4 pool
/// @notice Ownerless, immutable Uniswap v4 hook bound to exactly one pool:
///         (MONEYBACK, IMD, LP fee 12500 = 1.25%, tickSpacing 60, this hook) on Robinhood Chain.
///
///         FEE MATHS (all amounts in IMD, all rounding down, LP fee never overridden):
///         - base fee     = floor(imdLeg * 425 / 10_000) on every swap, both directions.
///         - surcharge    = floor(imdLeg * surchargeBps / 10_000) on sells (MONEYBACK -> IMD) only,
///                          surchargeBps = 2000 * max(0, 1800 - elapsed) / 1800 (integer maths),
///                          elapsed = block.timestamp - initializedAt. 2000 at initialization,
///                          1000 at +900 s, 0 at and after +1800 s, forever.
///         - hook take    = base fee + surcharge, always taken in IMD, never in MONEYBACK.
///
///         "imdLeg" is the IMD amount the pool swap is computed on:
///           * when IMD is the specified currency (exact-input buy, exact-output sell) it is
///             |params.amountSpecified|, the IMD amount the swapper named;
///           * when IMD is the unspecified currency (exact-output buy, exact-input sell) it is
///             the IMD amount the pool actually moved, |swapDelta.imd| as reported to afterSwap.
///
///         THE FOUR SWAP CASES:
///         1. exact-input buy  (IMD in, specified):      beforeSwap returns deltaSpecified = +fee.
///            PoolManager swaps (amountIn - fee) through the pool; the swapper pays amountIn.
///         2. exact-output buy (IMD in, unspecified):    afterSwap returns +fee on the unspecified
///            (IMD) side; the swapper pays poolImdIn + fee. No surcharge on buys.
///         3. exact-input sell (IMD out, unspecified):   afterSwap returns +fee on the unspecified
///            (IMD) side; the swapper receives poolImdOut - fee.
///         4. exact-output sell (IMD out, specified):    beforeSwap returns deltaSpecified = +fee.
///            PoolManager swaps for (amountOut + fee) IMD; the swapper receives exactly amountOut.
///            (afterSwapReturnDelta cannot be used here: it only acts on the unspecified currency,
///            which would be MONEYBACK.)
///
///         ACCRUAL: inside the callbacks the hook mints PoolManager ERC-6909 claims of IMD to
///         itself for the amount taken. The hook never calls anything but the PoolManager inside
///         a callback and never moves tokens there. `pending()` is the IMD claim balance.
///
///         SWEEP: `sweep()` is permissionless and is the only way funds leave: it unlocks the
///         PoolManager, burns every IMD claim the hook owns and takes the IMD to `payout`.
///
///         No owner, setter, pause, proxy, upgrade or selfdestruct exists.
contract MoneyBackHook is IHooks, IUnlockCallback {
    using DeltaLib for BalanceDelta;

    // ----------------------------------------------------------------------------------------- //
    //                                           constants                                        //
    // ----------------------------------------------------------------------------------------- //

    /// @notice IMD on Robinhood Chain (chainId 4663), the paired currency. Hardcoded.
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Base hook fee: 425 bps = 4.25% of the IMD leg, every swap, both directions.
    uint256 public constant BASE_FEE_BPS = 425;
    /// @notice Sell surcharge at pool initialization: 2000 bps = 20% of the IMD leg.
    uint256 public constant SURCHARGE_START_BPS = 2000;
    /// @notice Surcharge decays linearly to 0 over this many seconds after initialization.
    uint256 public constant SURCHARGE_DURATION = 1800;

    /// @notice Required pool LP fee (static, 1.25%) and tick spacing. Any other key is rejected.
    uint24 public constant POOL_LP_FEE = 12_500;
    int24 public constant POOL_TICK_SPACING = 60;

    /// @notice The exact hook-address flag bits this contract requires (0x20CC).
    uint160 public constant HOOK_FLAGS = HookFlags.MONEYBACK_FLAGS;

    // ----------------------------------------------------------------------------------------- //
    //                                           immutables                                       //
    // ----------------------------------------------------------------------------------------- //

    IPoolManager public immutable poolManager;
    /// @notice The MONEYBACK token.
    address public immutable launchToken;
    /// @notice Receiver of every sweep (the RoundPayout contract / owner). Only destination of funds.
    address public immutable payout;
    /// @notice True when IMD sorts below MONEYBACK, i.e. IMD is currency0 of the pool.
    bool public immutable imdIsCurrency0;
    /// @dev ERC-6909 claim id of IMD inside the PoolManager (uint160 of the address).
    uint256 internal immutable _imdId;

    // ----------------------------------------------------------------------------------------- //
    //                                             state                                          //
    // ----------------------------------------------------------------------------------------- //

    PoolKey internal _poolKey;
    PoolId internal _poolId;
    /// @notice Timestamp of pool initialization; 0 until the pool is bound.
    uint256 public initializedAt;
    /// @dev 1 = idle, 2 = a sweep is in progress (reentrancy guard and unlockCallback gate).
    uint256 private _sweepStatus = 1;

    // ----------------------------------------------------------------------------------------- //
    //                                       events and errors                                    //
    // ----------------------------------------------------------------------------------------- //

    event FeeAccrued(bool indexed isSell, uint256 baseFeeImd, uint256 surchargeImd, uint256 imdLeg);
    event Swept(uint256 imdAmount, address indexed to);
    event PoolBound(PoolId indexed id, uint256 initializedAt);

    error NotPoolManager();
    error InvalidPoolKey();
    error AlreadyBound();
    error NotBound();
    error ZeroSwapAmount();
    error Reentrancy();
    error UnexpectedCallback();
    error InvalidAddress();

    // ----------------------------------------------------------------------------------------- //
    //                                          constructor                                       //
    // ----------------------------------------------------------------------------------------- //

    /// @param manager The Uniswap v4 PoolManager ($poolManager).
    /// @param launchToken_ The MONEYBACK token ($token).
    /// @param payout_ Where sweep() sends IMD ($owner: the RoundPayout owner / engine treasury).
    /// @dev No external calls, no ETH. Reverts unless the deployment address carries exactly the
    ///      HOOK_FLAGS permission bits (CREATE2 salt mining is required).
    constructor(IPoolManager manager, address launchToken_, address payout_) {
        if (address(manager) == address(0) || launchToken_ == address(0) || payout_ == address(0)) {
            revert InvalidAddress();
        }
        if (launchToken_ == IMD) revert InvalidAddress();
        HookFlags.validateHookPermissions(address(this), HookFlags.MONEYBACK_FLAGS);

        poolManager = manager;
        launchToken = launchToken_;
        payout = payout_;
        imdIsCurrency0 = IMD < launchToken_;
        _imdId = uint256(uint160(IMD));
    }

    // ----------------------------------------------------------------------------------------- //
    //                                             views                                          //
    // ----------------------------------------------------------------------------------------- //

    /// @notice The bound pool key (all zero before the pool is initialized).
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice The bound pool id (zero before the pool is initialized).
    function poolId() external view returns (PoolId) {
        return _poolId;
    }

    /// @notice IMD fees accrued and not yet swept: the hook's ERC-6909 IMD claim balance.
    ///         Invariant: pending() == sum(FeeAccrued.base + FeeAccrued.surcharge) - sum(Swept).
    function pending() public view returns (uint256) {
        return poolManager.balanceOf(address(this), _imdId);
    }

    /// @notice Always 425.
    function baseFeeBps() external pure returns (uint256) {
        return BASE_FEE_BPS;
    }

    /// @notice Sell surcharge in bps at the current block: 2000 * max(0, 1800 - elapsed) / 1800.
    ///         0 before the pool is bound (there is nothing to sell) and 0 forever after +1800 s.
    function currentSurchargeBps() public view returns (uint256) {
        return _surchargeBpsAt(block.timestamp);
    }

    /// @notice Surcharge bps at an arbitrary timestamp (same formula as currentSurchargeBps).
    function surchargeBpsAt(uint256 timestamp) external view returns (uint256) {
        return _surchargeBpsAt(timestamp);
    }

    /// @notice The hook's fee split for a given IMD leg, as the callbacks compute it.
    /// @param isSell True for MONEYBACK -> IMD.
    /// @param imdLeg The IMD leg (see contract NatSpec for the definition per swap case).
    /// @return baseFee floor(imdLeg * 425 / 10_000)
    /// @return surcharge floor(imdLeg * currentSurchargeBps() / 10_000) for sells, else 0
    function quoteFees(bool isSell, uint256 imdLeg) external view returns (uint256 baseFee, uint256 surcharge) {
        return _fees(isSell, imdLeg);
    }

    // ----------------------------------------------------------------------------------------- //
    //                                        hook callbacks                                      //
    // ----------------------------------------------------------------------------------------- //

    /// @inheritdoc IHooks
    /// @dev Binds exactly one pool: currencies must be {MONEYBACK, IMD} (sorted), fee 12500,
    ///      tickSpacing 60, hooks == this. Records block.timestamp as the surcharge start.
    function beforeInitialize(address, PoolKey calldata key, uint160) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (initializedAt != 0) revert AlreadyBound();

        (address c0, address c1) = imdIsCurrency0 ? (IMD, launchToken) : (launchToken, IMD);
        if (
            Currency.unwrap(key.currency0) != c0 || Currency.unwrap(key.currency1) != c1 || key.fee != POOL_LP_FEE
                || key.tickSpacing != POOL_TICK_SPACING || key.hooks != address(this)
        ) revert InvalidPoolKey();

        _poolKey = key;
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        _poolId = id;
        initializedAt = block.timestamp;
        emit PoolBound(id, block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Cases 1 and 4 (IMD specified): returns deltaSpecified = base + surcharge and mints the
    ///      same amount of IMD claims to the hook. Cases 2 and 3: returns a zero delta and defers
    ///      to afterSwap. The LP fee override is always 0 (static-fee pool, never overridden).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _checkBound(key);
        if (params.amountSpecified == 0) revert ZeroSwapAmount();

        (bool isSell, bool imdSpecified) = _classify(params);
        if (!imdSpecified) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);

        uint256 imdLeg = _abs(params.amountSpecified);
        uint256 total = _accrue(isSell, imdLeg);
        return (IHooks.beforeSwap.selector, DeltaLib.toBeforeSwapDelta(_toInt128(total), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Cases 2 and 3 (IMD unspecified): returns base + surcharge as the hook's delta on the
    ///      unspecified (IMD) side and mints the same amount of IMD claims. Cases 1 and 4 return 0.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _checkBound(key);
        if (params.amountSpecified == 0) revert ZeroSwapAmount();

        (bool isSell, bool imdSpecified) = _classify(params);
        if (imdSpecified) return (IHooks.afterSwap.selector, 0);

        int128 imdDelta = imdIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 imdLeg = _abs(imdDelta);
        uint256 total = _accrue(isSell, imdLeg);
        return (IHooks.afterSwap.selector, _toInt128(total));
    }

    // ----------------------------------------------------------------------------------------- //
    //                                             sweep                                          //
    // ----------------------------------------------------------------------------------------- //

    /// @notice Permissionless: moves ALL accrued IMD (every IMD claim the hook owns) to `payout`.
    ///         Succeeds with a Swept(0, payout) event when nothing is pending. Reentrancy-safe.
    function sweep() external {
        if (_sweepStatus != 1) revert Reentrancy();
        _sweepStatus = 2;
        poolManager.unlock("");
        _sweepStatus = 1;
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only reachable from the PoolManager while sweep() is in progress. Burns the hook's IMD
    ///      claims (credits the hook's delta) and takes the same amount to `payout` (debits it), so
    ///      the hook's delta is zero when the lock closes.
    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (_sweepStatus != 2) revert UnexpectedCallback();

        uint256 amount = poolManager.balanceOf(address(this), _imdId);
        if (amount != 0) {
            poolManager.burn(address(this), _imdId, amount);
            poolManager.take(Currency.wrap(IMD), payout, amount);
        }
        emit Swept(amount, payout);
        return "";
    }

    // ----------------------------------------------------------------------------------------- //
    //                                           internals                                        //
    // ----------------------------------------------------------------------------------------- //

    /// @dev Computes the fee split, mints the IMD claims to the hook and emits FeeAccrued.
    function _accrue(bool isSell, uint256 imdLeg) internal returns (uint256 total) {
        (uint256 baseFee, uint256 surcharge) = _fees(isSell, imdLeg);
        total = baseFee + surcharge;
        // total <= 24.25% of imdLeg, so the pool always keeps a strictly positive swap amount.
        if (total != 0) poolManager.mint(address(this), _imdId, total);
        emit FeeAccrued(isSell, baseFee, surcharge, imdLeg);
    }

    function _fees(bool isSell, uint256 imdLeg) internal view returns (uint256 baseFee, uint256 surcharge) {
        baseFee = imdLeg * BASE_FEE_BPS / BPS;
        surcharge = isSell ? imdLeg * _surchargeBpsAt(block.timestamp) / BPS : 0;
    }

    function _surchargeBpsAt(uint256 timestamp) internal view returns (uint256) {
        uint256 start = initializedAt;
        if (start == 0 || timestamp < start) return 0;
        uint256 elapsed = timestamp - start;
        if (elapsed >= SURCHARGE_DURATION) return 0;
        return SURCHARGE_START_BPS * (SURCHARGE_DURATION - elapsed) / SURCHARGE_DURATION;
    }

    /// @dev isSell: input is MONEYBACK. imdSpecified: the specified currency is IMD, i.e.
    ///      exact-input buy (IMD in) or exact-output sell (IMD out).
    function _classify(SwapParams calldata params) internal view returns (bool isSell, bool imdSpecified) {
        bool inputIsImd = params.zeroForOne == imdIsCurrency0;
        isSell = !inputIsImd;
        bool exactInput = params.amountSpecified < 0;
        imdSpecified = exactInput ? inputIsImd : isSell;
    }

    function _checkBound(PoolKey calldata key) internal view {
        if (initializedAt == 0) revert NotBound();
        if (keccak256(abi.encode(key)) != PoolId.unwrap(_poolId)) revert InvalidPoolKey();
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function _toInt128(uint256 x) internal pure returns (int128) {
        // Swap amounts are int128 in v4, so a fee (a fraction of one) always fits.
        require(x <= uint256(uint128(type(int128).max)), "fee overflow");
        return int128(uint128(x));
    }
}
