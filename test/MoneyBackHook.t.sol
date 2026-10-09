// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    MoneyBackHook,
    HookFlags,
    DeltaLib,
    IPoolManager,
    IHooks,
    IUnlockCallback,
    PoolKey,
    PoolId,
    SwapParams,
    BalanceDelta,
    BeforeSwapDelta,
    Currency
} from "src/MoneyBackHook.sol";
import {MoneyBackToken} from "src/MoneyBackToken.sol";

// ============================================================================================= //
//  Self-contained harness. The project vendors no libraries (no forge-std), so the cheatcode      //
//  surface used here is declared inline against the standard cheatcode address.                  //
// ============================================================================================= //

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function warp(uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function etch(address, bytes calldata) external;
    function label(address, string calldata) external;
    function assume(bool) external pure;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool) external;
    function expectEmit(bool, bool, bool, bool, address) external;
    function expectEmit() external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function assertEq(uint256, uint256) external pure;
    function assertEq(uint256, uint256, string calldata) external pure;
    function assertEq(int256, int256, string calldata) external pure;
    function assertEq(address, address, string calldata) external pure;
    function assertEq(bytes32, bytes32, string calldata) external pure;
    function assertEq(bool, bool, string calldata) external pure;
    function assertTrue(bool, string calldata) external pure;
    function assertFalse(bool, string calldata) external pure;
    function assertLe(uint256, uint256, string calldata) external pure;
    function assertGe(uint256, uint256, string calldata) external pure;
    function assertApproxEqAbs(uint256, uint256, uint256, string calldata) external pure;
}

abstract contract TestBase {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        require(min <= max, "bound: min > max");
        if (x >= min && x <= max) return x;
        uint256 size = max - min;
        if (size == type(uint256).max) return x;
        return min + (x % (size + 1));
    }
}

// ============================================================================================= //
//                                             mocks                                             //
// ============================================================================================= //

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Plain mintable ERC20 with no constructor state, so it can be `etch`ed at the hardcoded IMD
///      address.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @dev Local stand-in for the Uniswap v4 PoolManager. It reproduces the parts of the documented
///      behaviour the hook depends on:
///        - unlock / unlockCallback with the "every delta must be zero when the lock closes" rule;
///        - the hook call order and delta plumbing of v4 `Hooks.beforeSwap` / `Hooks.afterSwap`
///          (specified / unspecified mapping, HookDeltaExceedsSwapAmount, return-length checks);
///        - ERC-6909 claims (mint debits the caller, burn credits it, take debits and pays out);
///        - sync / settle / take settlement.
///      The curve is a constant 1:1 price with the LP fee taken from the input (pips), so every
///      expected amount in the tests is exact integer arithmetic.
///      `maxOut` (0 = unlimited) models in-range liquidity running out / a price limit being hit:
///      the pool never delivers more than `maxOut` of the output currency and consumes only the
///      input that output costs, which is how v4 reports a partially filled exact-input or
///      exact-output order (the swap delta is smaller than the amount specified, no revert).
contract MockPoolManager is IPoolManager {
    using DeltaLib for BalanceDelta;

    uint256 internal constant PIPS = 1_000_000;

    error AlreadyUnlocked();
    error ManagerLocked();
    error CurrencyNotSettled();
    error PoolNotInitialized();
    error PoolAlreadyInitialized();
    error SwapAmountCannotBeZero();
    error InvalidHookResponse();
    error HookDeltaExceedsSwapAmount();
    error HookAddressNotValid(address hooks);
    error CurrenciesOutOfOrderOrEqual();
    error NotSynced();

    bool public unlocked;
    mapping(bytes32 => bool) public initialized;
    mapping(address => mapping(uint256 => uint256)) public balanceOf; // ERC-6909 claims
    mapping(address => mapping(address => int256)) public currencyDelta;
    uint256 public nonzeroDeltaCount;
    address private _syncedCurrency;
    uint256 private _syncedReserves;
    bool private _synced;

    /// @dev Raw pool delta of the last swap, before hook deltas were applied to the swapper.
    BalanceDelta public lastPoolDelta;
    /// @dev Hook delta of the last swap, as charged to the hook.
    BalanceDelta public lastHookDelta;
    uint256 public swapCount;
    /// @dev Liquidity cap on the output currency per swap; 0 = unlimited (full fills).
    uint256 public maxOut;

    /// @dev Test-only: cap the output the pool can deliver (partial fills). 0 restores full fills.
    function setMaxOut(uint256 cap) external {
        maxOut = cap;
    }

    function _hasFlag(address hooks, uint160 flag) internal pure returns (bool) {
        return uint160(hooks) & flag != 0;
    }

    function _accountDelta(address target, address currency, int256 amount) internal {
        if (amount == 0) return;
        int256 prev = currencyDelta[target][currency];
        int256 next = prev + amount;
        if (next == 0) nonzeroDeltaCount -= 1;
        else if (prev == 0) nonzeroDeltaCount += 1;
        currencyDelta[target][currency] = next;
    }

    function _accountPoolBalanceDelta(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(target, Currency.unwrap(key.currency0), delta.amount0());
        _accountDelta(target, Currency.unwrap(key.currency1), delta.amount1());
    }

    function _toBalanceDelta(int128 a0, int128 a1) internal pure returns (BalanceDelta d) {
        assembly ("memory-safe") {
            d := or(shl(128, a0), and(sub(shl(128, 1), 1), a1))
        }
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        if (nonzeroDeltaCount != 0) revert CurrencyNotSettled();
        unlocked = false;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        if (Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)) revert CurrenciesOutOfOrderOrEqual();
        // v4 Hooks.isValidHookAddress: a return-delta flag without its base flag is invalid.
        address h = key.hooks;
        if (
            (!_hasFlag(h, HookFlags.BEFORE_SWAP_FLAG) && _hasFlag(h, HookFlags.BEFORE_SWAP_RETURNS_DELTA_FLAG))
                || (!_hasFlag(h, HookFlags.AFTER_SWAP_FLAG) && _hasFlag(h, HookFlags.AFTER_SWAP_RETURNS_DELTA_FLAG))
        ) revert HookAddressNotValid(h);
        bytes32 id = keccak256(abi.encode(key));
        if (initialized[id]) revert PoolAlreadyInitialized();
        if (_hasFlag(h, HookFlags.BEFORE_INITIALIZE_FLAG)) {
            bytes4 sel = IHooks(h).beforeInitialize(msg.sender, key, sqrtPriceX96);
            if (sel != IHooks.beforeInitialize.selector) revert InvalidHookResponse();
        }
        initialized[id] = true;
        return 0;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta swapDelta)
    {
        if (!unlocked) revert ManagerLocked();
        if (params.amountSpecified == 0) revert SwapAmountCannotBeZero();
        if (!initialized[keccak256(abi.encode(key))]) revert PoolNotInitialized();

        // ---- Hooks.beforeSwap ----
        int256 amountToSwap = params.amountSpecified;
        int128 hookDeltaSpecified;
        int128 hookDeltaUnspecified;
        if (_hasFlag(key.hooks, HookFlags.BEFORE_SWAP_FLAG)) {
            (bool ok, bytes memory ret) =
                key.hooks.call(abi.encodeCall(IHooks.beforeSwap, (msg.sender, key, params, hookData)));
            if (!ok) _bubble(ret);
            if (ret.length != 96) revert InvalidHookResponse();
            (bytes4 sel, int256 rawDelta,) = abi.decode(ret, (bytes4, int256, uint24));
            if (sel != IHooks.beforeSwap.selector) revert InvalidHookResponse();
            if (_hasFlag(key.hooks, HookFlags.BEFORE_SWAP_RETURNS_DELTA_FLAG)) {
                hookDeltaSpecified = int128(rawDelta >> 128);
                hookDeltaUnspecified = int128(rawDelta);
                if (hookDeltaSpecified != 0) {
                    bool exactInput = amountToSwap < 0;
                    amountToSwap += hookDeltaSpecified;
                    if (exactInput ? amountToSwap > 0 : amountToSwap < 0) revert HookDeltaExceedsSwapAmount();
                }
            }
        }

        // ---- pool swap: constant 1:1 price, LP fee on the input in pips ----
        swapDelta = _poolSwap(key.fee, params.zeroForOne, amountToSwap);
        lastPoolDelta = swapDelta;

        // ---- Hooks.afterSwap ----
        if (_hasFlag(key.hooks, HookFlags.AFTER_SWAP_FLAG)) {
            (bool ok, bytes memory ret) =
                key.hooks.call(abi.encodeCall(IHooks.afterSwap, (msg.sender, key, params, swapDelta, hookData)));
            if (!ok) _bubble(ret);
            if (ret.length != 64) revert InvalidHookResponse();
            (bytes4 sel, int256 d) = abi.decode(ret, (bytes4, int256));
            if (sel != IHooks.afterSwap.selector) revert InvalidHookResponse();
            if (_hasFlag(key.hooks, HookFlags.AFTER_SWAP_RETURNS_DELTA_FLAG)) {
                hookDeltaUnspecified += int128(d);
            }
        }
        BalanceDelta hookDelta;
        if (hookDeltaUnspecified != 0 || hookDeltaSpecified != 0) {
            hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
                ? _toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
                : _toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);
            swapDelta =
                _toBalanceDelta(swapDelta.amount0() - hookDelta.amount0(), swapDelta.amount1() - hookDelta.amount1());
        }
        lastHookDelta = hookDelta;
        if (BalanceDelta.unwrap(hookDelta) != 0) _accountPoolBalanceDelta(key, hookDelta, key.hooks);
        _accountPoolBalanceDelta(key, swapDelta, msg.sender);
        swapCount += 1;
    }

    function _poolSwap(uint24 fee, bool zeroForOne, int256 amountToSwap) internal view returns (BalanceDelta) {
        uint256 amountIn;
        uint256 amountOut;
        uint256 cap = maxOut;
        if (amountToSwap < 0) {
            amountIn = uint256(-amountToSwap);
            amountOut = amountIn * (PIPS - fee) / PIPS;
            if (cap != 0 && amountOut > cap) {
                // liquidity ran out: only the input that buys `cap` output is consumed
                amountOut = cap;
                amountIn = (amountOut * PIPS + (PIPS - fee) - 1) / (PIPS - fee);
            }
        } else {
            amountOut = uint256(amountToSwap);
            if (cap != 0 && amountOut > cap) amountOut = cap;
            amountIn = (amountOut * PIPS + (PIPS - fee) - 1) / (PIPS - fee);
        }
        int128 inDelta = -int128(uint128(amountIn));
        int128 outDelta = int128(uint128(amountOut));
        return zeroForOne ? _toBalanceDelta(inDelta, outDelta) : _toBalanceDelta(outDelta, inDelta);
    }

    function _bubble(bytes memory ret) internal pure {
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    function sync(Currency currency) external {
        _syncedCurrency = Currency.unwrap(currency);
        _syncedReserves = IERC20Like(_syncedCurrency).balanceOf(address(this));
        _synced = true;
    }

    function settle() external payable returns (uint256 paid) {
        if (!unlocked) revert ManagerLocked();
        if (!_synced) revert NotSynced();
        paid = IERC20Like(_syncedCurrency).balanceOf(address(this)) - _syncedReserves;
        _accountDelta(msg.sender, _syncedCurrency, int256(paid));
        _synced = false;
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (!unlocked) revert ManagerLocked();
        _accountDelta(msg.sender, Currency.unwrap(currency), -int256(amount));
        require(IERC20Like(Currency.unwrap(currency)).transfer(to, amount), "take failed");
    }

    function mint(address to, uint256 id, uint256 amount) external {
        if (!unlocked) revert ManagerLocked();
        _accountDelta(msg.sender, address(uint160(id)), -int256(amount));
        balanceOf[to][id] += amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        if (!unlocked) revert ManagerLocked();
        require(from == msg.sender, "not operator");
        _accountDelta(msg.sender, address(uint160(id)), int256(amount));
        balanceOf[from][id] -= amount;
    }

    /// @dev ERC-6909 transfer of claims (anyone can hand claims to any address, including the hook).
    function transfer(address to, uint256 id, uint256 amount) external returns (bool) {
        balanceOf[msg.sender][id] -= amount;
        balanceOf[to][id] += amount;
        return true;
    }

    /// @dev Test-only: lets the test open the lock and run arbitrary PoolManager calls as a stranger.
    function unlockedForTest(bool v) external {
        unlocked = v;
    }
}

/// @dev Minimal swapper: unlocks, swaps once, settles its own deltas. The hook sees it as `sender`.
contract Swapper is IUnlockCallback {
    using DeltaLib for BalanceDelta;

    MockPoolManager public immutable pm;

    constructor(MockPoolManager pm_) {
        pm = pm_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(pm.unlock(abi.encode(key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        BalanceDelta d = pm.swap(key, params, "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return abi.encode(d);
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            pm.sync(c);
            IERC20Like(Currency.unwrap(c)).transfer(address(pm), uint256(uint128(-amt)));
            pm.settle();
        } else if (amt > 0) {
            pm.take(c, address(this), uint256(uint128(amt)));
        }
    }
}

// ============================================================================================= //
//                                          shared fixture                                       //
// ============================================================================================= //

abstract contract HookFixture is TestBase {
    using DeltaLib for BalanceDelta;

    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint256 internal constant PIPS = 1_000_000;
    uint24 internal constant LP_FEE = 12_500;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant BASE_BPS = 425;
    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant LIQ = 1e30;

    bytes32 internal constant FEE_ACCRUED_SIG = keccak256("FeeAccrued(bool,uint256,uint256,uint256)");
    bytes32 internal constant SWEPT_SIG = keccak256("Swept(uint256,address)");

    MockPoolManager internal pm;
    MockERC20 internal imd;
    MoneyBackToken internal token;
    MoneyBackHook internal hook;
    Swapper internal swapper;
    address internal payout = address(0xBEEF);
    PoolKey internal key;
    bool internal imdIs0;

    function _setUpFixture() internal {
        vm.warp(T0);
        pm = new MockPoolManager();
        vm.etch(IMD, type(MockERC20).runtimeCode);
        imd = MockERC20(IMD);
        token = new MoneyBackToken();
        hook = _deployHook(address(pm), address(token), payout);
        swapper = new Swapper(pm);
        imdIs0 = IMD < address(token);
        key = _ourKey();
        // liquidity for the constant-price pool and balances for the swapper
        imd.mint(address(pm), LIQ);
        token.transfer(address(pm), 1e26);
        imd.mint(address(swapper), LIQ);
        token.transfer(address(swapper), 1e26);
        vm.label(address(hook), "hook");
        vm.label(IMD, "IMD");
    }

    function _ourKey() internal view returns (PoolKey memory k) {
        (address c0, address c1) = imdIs0 ? (IMD, address(token)) : (address(token), IMD);
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LP_FEE, 60, address(hook));
    }

    function _initPool() internal {
        pm.initialize(key, 79228162514264337593543950336);
    }

    /// @dev Pure CREATE2 salt mining: the hook address must carry exactly the 0x20CC flag bits.
    function _deployHook(address manager, address launchToken, address payout_) internal returns (MoneyBackHook) {
        bytes memory initCode =
            abi.encodePacked(type(MoneyBackHook).creationCode, abi.encode(manager, launchToken, payout_));
        bytes32 initHash = keccak256(initCode);
        for (uint256 salt = 0; salt < 1_000_000; ++salt) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), initHash))))
            );
            if (uint160(predicted) & HookFlags.ALL_HOOK_MASK == HookFlags.MONEYBACK_FLAGS) {
                MoneyBackHook h = new MoneyBackHook{salt: bytes32(salt)}(IPoolManager(manager), launchToken, payout_);
                require(address(h) == predicted, "create2 mismatch");
                return h;
            }
        }
        revert("no salt found");
    }

    // ---- swap helpers: positive amount = exact output, negative = exact input ----

    function _params(bool isSell, bool exactInput, uint256 amount) internal view returns (SwapParams memory) {
        // buy: IMD in. IMD is the input when zeroForOne == imdIs0.
        bool zeroForOne = isSell ? !imdIs0 : imdIs0;
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        return SwapParams(zeroForOne, specified, 0);
    }

    function _imdDelta(BalanceDelta d) internal view returns (int256) {
        return imdIs0 ? d.amount0() : d.amount1();
    }

    function _tokenDelta(BalanceDelta d) internal view returns (int256) {
        return imdIs0 ? d.amount1() : d.amount0();
    }

    struct Accrued {
        bool found;
        bool isSell;
        uint256 base;
        uint256 surcharge;
        uint256 imdLeg;
        uint256 count;
    }

    function _findFeeAccrued(Vm.Log[] memory logs) internal view returns (Accrued memory a) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEE_ACCRUED_SIG) {
                a.found = true;
                a.count += 1;
                a.isSell = uint256(logs[i].topics[1]) == 1;
                (a.base, a.surcharge, a.imdLeg) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }

    function _surchargeBps(uint256 elapsed) internal pure returns (uint256) {
        if (elapsed >= 1800) return 0;
        return 2000 * (1800 - elapsed) / 1800;
    }

    /// @dev Runs one swap and checks every fee rule against the raw pool delta and the swapper's
    ///      net result. Returns the hook's take.
    function _swapAndCheck(bool isSell, bool exactInput, uint256 amount, uint256 elapsed)
        internal
        returns (uint256 total)
    {
        uint256 pendingBefore = hook.pending();
        uint256 imdBefore = imd.balanceOf(address(swapper));
        uint256 tokBefore = token.balanceOf(address(swapper));

        vm.recordLogs();
        BalanceDelta d = swapper.swap(key, _params(isSell, exactInput, amount));
        Accrued memory a = _findFeeAccrued(vm.getRecordedLogs());

        vm.assertEq(a.count, 1, "exactly one FeeAccrued per swap");
        vm.assertEq(a.isSell, isSell, "isSell flag");

        // imdLeg definition per case
        bool imdSpecified = exactInput ? !isSell : isSell;
        uint256 poolImd = _abs(_imdDelta(pm.lastPoolDelta()));
        if (imdSpecified) {
            vm.assertEq(a.imdLeg, amount, "imdLeg == |amountSpecified| when IMD is specified");
        } else {
            vm.assertEq(a.imdLeg, poolImd, "imdLeg == pool IMD delta when IMD is unspecified");
        }

        // fee formulas, rounded down
        vm.assertEq(a.base, a.imdLeg * BASE_BPS / BPS, "base fee == floor(imdLeg*425/10000)");
        uint256 expectedSurcharge = isSell ? a.imdLeg * _surchargeBps(elapsed) / BPS : 0;
        vm.assertApproxEqAbs(a.surcharge, expectedSurcharge, 1, "surcharge within 1 wei of formula");
        vm.assertEq(a.surcharge, expectedSurcharge, "surcharge exact (integer maths)");
        total = a.base + a.surcharge;

        // accrual: claims minted exactly equal the take, never MONEYBACK
        vm.assertEq(hook.pending() - pendingBefore, total, "pending grows by base + surcharge");
        vm.assertEq(pm.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "no MONEYBACK claims");

        // the hook's delta is taken in IMD only
        vm.assertEq(_tokenDelta(pm.lastHookDelta()), 0, "hook delta has no MONEYBACK side");
        vm.assertEq(_imdDelta(pm.lastHookDelta()), int256(total), "hook delta == take in IMD");

        // swapper's net IMD: pool amount +/- the hook's take; MONEYBACK untouched by the hook
        int256 swapperImd = _imdDelta(d);
        int256 swapperTok = _tokenDelta(d);
        int256 poolImdSigned = _imdDelta(pm.lastPoolDelta());
        vm.assertEq(swapperImd, poolImdSigned - int256(total), "swapper IMD == pool IMD - hook take");
        vm.assertEq(swapperTok, _tokenDelta(pm.lastPoolDelta()), "swapper MONEYBACK == pool MONEYBACK");
        vm.assertEq(
            int256(imd.balanceOf(address(swapper))) - int256(imdBefore), swapperImd, "IMD balance moved by delta"
        );
        vm.assertEq(
            int256(token.balanceOf(address(swapper))) - int256(tokBefore),
            swapperTok,
            "MONEYBACK balance moved by delta"
        );
        if (isSell) {
            // a sell never costs the seller IMD; it yields 0 only when the pool output rounds to 0
            vm.assertTrue(swapperImd >= 0, "sell never pays IMD");
            if (poolImd >= 2) vm.assertTrue(swapperImd > 0, "sell receives IMD");
        } else {
            vm.assertTrue(swapperImd < 0, "buy pays IMD");
        }
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @dev Builds a pool BalanceDelta with `imdAmt` on the IMD side and `tokAmt` on the MONEYBACK side.
    function _delta(int128 imdAmt, int128 tokAmt) internal view returns (BalanceDelta d) {
        (int128 a0, int128 a1) = imdIs0 ? (imdAmt, tokAmt) : (tokAmt, imdAmt);
        assembly ("memory-safe") {
            d := or(shl(128, a0), and(sub(shl(128, 1), 1), a1))
        }
    }

    /// @dev Expected output of the mock pool for `amountIn`, after the LP fee and the `maxOut` cap.
    function _poolOutFor(uint256 amountIn) internal view returns (uint256 out) {
        out = amountIn * (PIPS - LP_FEE) / PIPS;
        uint256 cap = pm.maxOut();
        if (cap != 0 && out > cap) out = cap;
    }

    /// @dev Exact input the mock pool charges for `amountOut` (ceil), the same maths as the mock.
    function _poolInFor(uint256 amountOut) internal pure returns (uint256) {
        return (amountOut * PIPS + (PIPS - LP_FEE) - 1) / (PIPS - LP_FEE);
    }
}

// ============================================================================================= //
//                                         deployment tests                                      //
// ============================================================================================= //

contract MoneyBackHookDeployTest is HookFixture {
    function setUp() public {
        _setUpFixture();
    }

    function test_hookAddressFlagBitsMatchPermissions() public view {
        uint160 bits = uint160(address(hook)) & HookFlags.ALL_HOOK_MASK;
        vm.assertEq(uint256(bits), 0x20CC, "flag bits == 0x20CC");
        vm.assertEq(uint256(hook.HOOK_FLAGS()), 0x20CC, "HOOK_FLAGS constant");
        // exactly these five flags, nothing else
        vm.assertTrue(bits & HookFlags.BEFORE_INITIALIZE_FLAG != 0, "beforeInitialize");
        vm.assertTrue(bits & HookFlags.BEFORE_SWAP_FLAG != 0, "beforeSwap");
        vm.assertTrue(bits & HookFlags.AFTER_SWAP_FLAG != 0, "afterSwap");
        vm.assertTrue(bits & HookFlags.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0, "beforeSwapReturnDelta");
        vm.assertTrue(bits & HookFlags.AFTER_SWAP_RETURNS_DELTA_FLAG != 0, "afterSwapReturnDelta");
        vm.assertTrue(bits & HookFlags.AFTER_INITIALIZE_FLAG == 0, "no afterInitialize");
        vm.assertTrue(bits & HookFlags.BEFORE_ADD_LIQUIDITY_FLAG == 0, "no beforeAddLiquidity");
        vm.assertTrue(bits & HookFlags.AFTER_ADD_LIQUIDITY_FLAG == 0, "no afterAddLiquidity");
        vm.assertTrue(bits & HookFlags.BEFORE_REMOVE_LIQUIDITY_FLAG == 0, "no beforeRemoveLiquidity");
        vm.assertTrue(bits & HookFlags.AFTER_REMOVE_LIQUIDITY_FLAG == 0, "no afterRemoveLiquidity");
        vm.assertTrue(bits & HookFlags.BEFORE_DONATE_FLAG == 0, "no beforeDonate");
        vm.assertTrue(bits & HookFlags.AFTER_DONATE_FLAG == 0, "no afterDonate");
        vm.assertTrue(bits & HookFlags.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG == 0, "no addLiq delta");
        vm.assertTrue(bits & HookFlags.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG == 0, "no removeLiq delta");
    }

    function test_constructorRevertsAtAddressWithoutFlags() public {
        // plain CREATE from a fresh deployer: the address carries arbitrary low bits
        PlainDeployer d = new PlainDeployer();
        (bool ok, address at, bytes memory err) = d.tryDeploy(address(pm), address(token), payout);
        if (uint160(at) & HookFlags.ALL_HOOK_MASK == HookFlags.MONEYBACK_FLAGS) {
            vm.assertTrue(ok, "a flagged address deploys");
        } else {
            vm.assertFalse(ok, "unflagged address must not deploy");
            vm.assertEq(bytes32(bytes4(err)), bytes32(HookFlags.HookAddressNotValid.selector), "HookAddressNotValid");
        }
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(MoneyBackHook.InvalidAddress.selector);
        new MoneyBackHook(IPoolManager(address(0)), address(token), payout);
        vm.expectRevert(MoneyBackHook.InvalidAddress.selector);
        new MoneyBackHook(IPoolManager(address(pm)), address(0), payout);
        vm.expectRevert(MoneyBackHook.InvalidAddress.selector);
        new MoneyBackHook(IPoolManager(address(pm)), address(token), address(0));
        // launch token equal to IMD is rejected before the flag check
        vm.expectRevert(MoneyBackHook.InvalidAddress.selector);
        new MoneyBackHook(IPoolManager(address(pm)), IMD, payout);
    }

    function test_immutablesAndConstants() public view {
        vm.assertEq(address(hook.poolManager()), address(pm), "poolManager");
        vm.assertEq(hook.launchToken(), address(token), "launchToken");
        vm.assertEq(hook.payout(), payout, "payout");
        vm.assertEq(hook.IMD(), IMD, "IMD hardcoded");
        vm.assertEq(hook.baseFeeBps(), 425, "baseFeeBps");
        vm.assertEq(hook.BASE_FEE_BPS(), 425, "BASE_FEE_BPS");
        vm.assertEq(hook.SURCHARGE_START_BPS(), 2000, "surcharge start");
        vm.assertEq(hook.SURCHARGE_DURATION(), 1800, "surcharge duration");
        vm.assertEq(uint256(hook.POOL_LP_FEE()), 12_500, "lp fee");
        vm.assertEq(uint256(int256(hook.POOL_TICK_SPACING())), 60, "tick spacing");
        vm.assertEq(hook.imdIsCurrency0(), IMD < address(token), "imdIsCurrency0");
        vm.assertEq(hook.initializedAt(), 0, "unbound");
        vm.assertEq(hook.pending(), 0, "nothing pending");
        vm.assertEq(hook.currentSurchargeBps(), 0, "no surcharge before bind");
        vm.assertEq(PoolId.unwrap(hook.poolId()), bytes32(0), "poolId zero before bind");
        PoolKey memory k = hook.poolKey();
        vm.assertEq(Currency.unwrap(k.currency0), address(0), "key empty before bind");
        vm.assertEq(k.hooks, address(0), "key hooks empty before bind");
    }

    function test_noPrivilegedSurface() public {
        // No owner / setter / pause / upgrade entry points exist: these selectors must not be callable.
        bytes4[7] memory sels = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("setPayout(address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("setFee(uint256)")),
            bytes4(keccak256("withdraw(address,uint256)"))
        ];
        for (uint256 i; i < sels.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSelector(sels[i], address(this)));
            vm.assertFalse(ok, "privileged selector must not exist");
        }
        // and the hook takes no ETH
        (bool sent,) = address(hook).call{value: 1}("");
        vm.assertFalse(sent, "hook rejects ETH");
    }

    receive() external payable {}
}

contract PlainDeployer {
    function tryDeploy(address pm, address token, address payout)
        external
        returns (bool ok, address at, bytes memory err)
    {
        at = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), uint8(1))))));
        try new MoneyBackHook(IPoolManager(pm), token, payout) returns (MoneyBackHook h) {
            ok = true;
            at = address(h);
        } catch (bytes memory e) {
            err = e;
        }
    }
}

// ============================================================================================= //
//                                        unit / adversarial                                     //
// ============================================================================================= //

contract MoneyBackHookTest is HookFixture {
    using DeltaLib for BalanceDelta;

    function setUp() public {
        _setUpFixture();
    }

    // ---------------------------------------- beforeInitialize ---------------------------------- //

    function test_initializeBindsPoolAndRecordsTimestamp() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit MoneyBackHook.PoolBound(PoolId.wrap(keccak256(abi.encode(key))), T0);
        _initPool();
        vm.assertEq(hook.initializedAt(), T0, "initializedAt");
        vm.assertEq(PoolId.unwrap(hook.poolId()), keccak256(abi.encode(key)), "poolId");
        PoolKey memory k = hook.poolKey();
        vm.assertEq(Currency.unwrap(k.currency0), Currency.unwrap(key.currency0), "c0");
        vm.assertEq(Currency.unwrap(k.currency1), Currency.unwrap(key.currency1), "c1");
        vm.assertEq(uint256(k.fee), 12_500, "fee");
        vm.assertEq(uint256(int256(k.tickSpacing)), 60, "tickSpacing");
        vm.assertEq(k.hooks, address(hook), "hooks");
        vm.assertEq(hook.currentSurchargeBps(), 2000, "surcharge starts at 2000");
    }

    function test_initializeRejectsNonPoolManagerCaller() public {
        vm.expectRevert(MoneyBackHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, 0);
        vm.prank(address(0xBAD));
        vm.expectRevert(MoneyBackHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, 0);
        vm.assertEq(hook.initializedAt(), 0, "still unbound");
    }

    function test_initializeRejectsWrongFee() public {
        PoolKey memory k = key;
        k.fee = 3000;
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        pm.initialize(k, 1 << 96);
        k.fee = 12_501;
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        pm.initialize(k, 1 << 96);
        k.fee = 0x800000; // dynamic fee flag
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        pm.initialize(k, 1 << 96);
    }

    function test_initializeRejectsWrongTickSpacing() public {
        PoolKey memory k = key;
        k.tickSpacing = 10;
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        pm.initialize(k, 1 << 96);
        k.tickSpacing = 61;
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        pm.initialize(k, 1 << 96);
    }

    function test_initializeRejectsWrongCurrencies() public {
        MockERC20 other = new MockERC20();
        // replace IMD with another token
        (address a, address b) =
            address(other) < address(token) ? (address(other), address(token)) : (address(token), address(other));
        PoolKey memory k = PoolKey(Currency.wrap(a), Currency.wrap(b), LP_FEE, 60, address(hook));
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        pm.initialize(k, 1 << 96);
        // replace MONEYBACK with another token, keep IMD
        (a, b) = address(other) < IMD ? (address(other), IMD) : (IMD, address(other));
        k = PoolKey(Currency.wrap(a), Currency.wrap(b), LP_FEE, 60, address(hook));
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        pm.initialize(k, 1 << 96);
        // native ETH paired with MONEYBACK
        k = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), LP_FEE, 60, address(hook));
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        pm.initialize(k, 1 << 96);
        // reversed order, delivered straight to the hook as the PoolManager
        k = PoolKey(key.currency1, key.currency0, LP_FEE, 60, address(hook));
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        hook.beforeInitialize(address(this), k, 1 << 96);
    }

    function test_initializeRejectsWrongPrice() public {
        // PoolManager.initialize is permissionless: a front-runner cannot pick the starting price.
        uint160 launch = 79228162514264337593543950336;
        vm.assertEq(uint256(hook.LAUNCH_SQRT_PRICE_X96()), uint256(launch), "launch price constant");
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.InvalidInitialPrice.selector, launch - 1));
        pm.initialize(key, launch - 1);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.InvalidInitialPrice.selector, launch + 1));
        pm.initialize(key, launch + 1);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.InvalidInitialPrice.selector, uint160(0)));
        pm.initialize(key, 0);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.InvalidInitialPrice.selector, type(uint160).max));
        pm.initialize(key, type(uint160).max);
        vm.assertEq(hook.initializedAt(), 0, "still unbound after every bad price");
        // the right price binds
        pm.initialize(key, launch);
        vm.assertEq(hook.initializedAt(), T0, "bound at the launch price");
    }

    function test_initializeRejectsWrongHooksField() public {
        PoolKey memory k = key;
        k.hooks = address(0x1234);
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        hook.beforeInitialize(address(this), k, 1 << 96);
    }

    function test_initializeOnlyOnce() public {
        _initPool();
        // same key again through the manager is rejected by the manager, so hit the hook directly
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.AlreadyBound.selector);
        hook.beforeInitialize(address(this), key, 1 << 96);
        // a different valid-looking key cannot bind a second pool either
        PoolKey memory k = key;
        k.fee = 3000;
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.AlreadyBound.selector);
        hook.beforeInitialize(address(this), k, 1 << 96);
    }

    // ------------------------------------------- swaps ------------------------------------------ //

    function test_swapRevertsBeforeBind() public {
        vm.expectRevert(MockPoolManager.PoolNotInitialized.selector);
        swapper.swap(key, _params(false, true, 1e18));
        // and the hook itself refuses callbacks while unbound
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.NotBound.selector);
        hook.beforeSwap(address(this), key, _params(false, true, 1e18), "");
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.NotBound.selector);
        hook.afterSwap(address(this), key, _params(false, true, 1e18), BalanceDelta.wrap(0), "");
    }

    function test_callbacksRejectNonPoolManager() public {
        _initPool();
        SwapParams memory p = _params(false, true, 1e18);
        vm.expectRevert(MoneyBackHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(MoneyBackHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(MoneyBackHook.NotPoolManager.selector);
        hook.unlockCallback("");
        vm.prank(address(swapper));
        vm.expectRevert(MoneyBackHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.assertEq(hook.pending(), 0, "nothing accrued by a stranger");
    }

    function test_callbacksRejectWrongPoolKey() public {
        _initPool();
        PoolKey memory k = key;
        k.fee = 3000;
        SwapParams memory p = _params(false, true, 1e18);
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        hook.beforeSwap(address(this), k, p, "");
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        hook.afterSwap(address(this), k, p, BalanceDelta.wrap(0), "");
        k = key;
        k.hooks = address(0);
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.InvalidPoolKey.selector);
        hook.beforeSwap(address(this), k, p, "");
    }

    function test_zeroSwapRejected() public {
        _initPool();
        SwapParams memory p = SwapParams(true, 0, 0);
        vm.expectRevert(MockPoolManager.SwapAmountCannotBeZero.selector);
        swapper.swap(key, p);
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.ZeroSwapAmount.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.ZeroSwapAmount.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
    }

    function test_fourCases_t0() public {
        _initPool();
        _swapAndCheck(false, true, 1000e18, 0);
        _swapAndCheck(false, false, 1000e18, 0);
        _swapAndCheck(true, true, 1000e18, 0);
        _swapAndCheck(true, false, 1000e18, 0);
    }

    function test_fourCases_t900() public {
        _initPool();
        vm.warp(T0 + 900);
        vm.assertEq(hook.currentSurchargeBps(), 1000, "half way");
        _swapAndCheck(false, true, 1000e18, 900);
        _swapAndCheck(false, false, 1000e18, 900);
        _swapAndCheck(true, true, 1000e18, 900);
        _swapAndCheck(true, false, 1000e18, 900);
    }

    function test_fourCases_t1800() public {
        _initPool();
        vm.warp(T0 + 1800);
        vm.assertEq(hook.currentSurchargeBps(), 0, "boundary: zero at exactly 1800 s");
        _swapAndCheck(false, true, 1000e18, 1800);
        _swapAndCheck(false, false, 1000e18, 1800);
        _swapAndCheck(true, true, 1000e18, 1800);
        _swapAndCheck(true, false, 1000e18, 1800);
    }

    function test_fourCases_oneDay() public {
        _initPool();
        vm.warp(T0 + 1 days);
        vm.assertEq(hook.currentSurchargeBps(), 0, "zero forever");
        _swapAndCheck(false, true, 1000e18, 1 days);
        _swapAndCheck(false, false, 1000e18, 1 days);
        _swapAndCheck(true, true, 1000e18, 1 days);
        _swapAndCheck(true, false, 1000e18, 1 days);
    }

    function test_surchargeBoundary1799vs1800() public {
        _initPool();
        vm.warp(T0 + 1799);
        vm.assertEq(hook.currentSurchargeBps(), uint256(1), "1799 s: 1 bps");
        uint256 take1799 = _swapAndCheck(true, true, 1800e18, 1799);
        vm.warp(T0 + 1800);
        uint256 take1800 = _swapAndCheck(true, true, 1800e18, 1800);
        vm.assertTrue(take1799 > take1800, "surcharge still charged one second before the end");
        uint256 poolOut = 1800e18 * (PIPS - LP_FEE) / PIPS;
        vm.assertEq(take1800, poolOut * 425 / BPS, "base only at 1800 s");
        vm.assertEq(take1799, poolOut * 425 / BPS + poolOut * 1 / BPS, "base + 1 bps at 1799 s");
    }

    function test_surchargeNeverOnBuys() public {
        _initPool();
        for (uint256 t = 0; t <= 1800; t += 300) {
            vm.warp(T0 + t);
            vm.recordLogs();
            swapper.swap(key, _params(false, true, 10e18));
            Accrued memory a = _findFeeAccrued(vm.getRecordedLogs());
            vm.assertEq(a.surcharge, 0, "buy exact-in surcharge is zero");
            vm.recordLogs();
            swapper.swap(key, _params(false, false, 10e18));
            a = _findFeeAccrued(vm.getRecordedLogs());
            vm.assertEq(a.surcharge, 0, "buy exact-out surcharge is zero");
        }
    }

    function test_acceptanceSellAtT0AndAfter() public {
        _initPool();
        uint256 amount = 10_000e18;
        uint256 poolOut = amount * (PIPS - LP_FEE) / PIPS; // 1.25% LP fee
        vm.assertEq(poolOut, amount * 98_750 / 100_000, "LP fee is 1.25%");
        uint256 base = poolOut * 425 / BPS; // 4.25%
        uint256 surcharge = poolOut * 2000 / BPS; // 20%

        uint256 before = imd.balanceOf(address(swapper));
        uint256 take = _swapAndCheck(true, true, amount, 0);
        vm.assertEq(take, base + surcharge, "t=0: 4.25% + 20% of the IMD leg");
        vm.assertEq(imd.balanceOf(address(swapper)) - before, poolOut - base - surcharge, "received");

        vm.warp(T0 + 1800);
        before = imd.balanceOf(address(swapper));
        take = _swapAndCheck(true, true, amount, 1800);
        vm.assertEq(take, base, "t>=1800: 4.25% only");
        vm.assertEq(imd.balanceOf(address(swapper)) - before, poolOut - base, "received");
        // total 5.5% of the gross: LP fee + hook fee, expressed on the sell's IMD leg
        uint256 totalTaken = amount - (poolOut - base);
        vm.assertEq(totalTaken, amount * 125 / BPS + base, "1.25% + 4.25%");
    }

    function test_feeOverrideNeverSet() public {
        _initPool();
        pm.unlockedForTest(true); // the callback mints claims, which the manager only allows unlocked
        vm.prank(address(pm));
        (bytes4 sel, BeforeSwapDelta d, uint24 feeOverride) =
            hook.beforeSwap(address(swapper), key, _params(false, true, 1e18), "");
        vm.assertEq(sel == IHooks.beforeSwap.selector, true, "selector");
        vm.assertEq(uint256(feeOverride), 0, "no LP fee override");
        // IMD specified: specified delta == 425 bps, unspecified 0
        int128 specified = int128(BeforeSwapDelta.unwrap(d) >> 128);
        int128 unspecified = int128(BeforeSwapDelta.unwrap(d));
        vm.assertEq(int256(specified), int256(1e18 * 425 / BPS), "specified delta");
        vm.assertEq(int256(unspecified), 0, "unspecified delta");
    }

    function test_beforeSwapReturnsZeroWhenImdUnspecified() public {
        _initPool();
        // exact-output buy: specified = MONEYBACK -> beforeSwap defers
        vm.prank(address(pm));
        (, BeforeSwapDelta d,) = hook.beforeSwap(address(swapper), key, _params(false, false, 1e18), "");
        vm.assertEq(BeforeSwapDelta.unwrap(d), 0, "zero before-delta for exact-output buy");
        vm.assertEq(hook.pending(), 0, "nothing minted");
        // exact-input sell: specified = MONEYBACK -> beforeSwap defers
        vm.prank(address(pm));
        (, d,) = hook.beforeSwap(address(swapper), key, _params(true, true, 1e18), "");
        vm.assertEq(BeforeSwapDelta.unwrap(d), 0, "zero before-delta for exact-input sell");
    }

    function test_afterSwapReturnsZeroWhenImdSpecified() public {
        _initPool();
        // Case 1, full fill: the pool consumed exactly amountIn - fee of IMD.
        uint256 fee = 1e18 * 425 / BPS;
        BalanceDelta full = _delta(-int128(uint128(1e18 - fee)), int128(uint128(_poolOutFor(1e18 - fee))));
        vm.prank(address(pm));
        (, int128 d) = hook.afterSwap(address(swapper), key, _params(false, true, 1e18), full, "");
        vm.assertEq(int256(d), 0, "after-delta zero for exact-input buy");
        // Case 4, full fill at t=0: the pool produced exactly amountOut + base + surcharge of IMD.
        uint256 feeSell = fee + 1e18 * 2000 / BPS;
        full = _delta(int128(uint128(1e18 + feeSell)), -int128(uint128(_poolInFor(1e18 + feeSell))));
        vm.prank(address(pm));
        (, d) = hook.afterSwap(address(swapper), key, _params(true, false, 1e18), full, "");
        vm.assertEq(int256(d), 0, "after-delta zero for exact-output sell");
        vm.assertEq(hook.pending(), 0, "nothing minted");
    }

    function test_afterSwapRevertsPartialFillWhenImdSpecified() public {
        _initPool();
        uint256 fee = 1e18 * 425 / BPS;
        uint256 expectedBuy = 1e18 - fee;
        // Case 1: the pool moved one wei less IMD than the order net of the fee -> PartialFill.
        BalanceDelta d = _delta(-int128(uint128(expectedBuy - 1)), 1);
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.PartialFill.selector, expectedBuy, expectedBuy - 1));
        hook.afterSwap(address(swapper), key, _params(false, true, 1e18), d, "");
        // ... and a zero delta (nothing moved at all)
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.PartialFill.selector, expectedBuy, 0));
        hook.afterSwap(address(swapper), key, _params(false, true, 1e18), BalanceDelta.wrap(0), "");
        // ... and one wei more (never produced by v4, but the equality must be strict both ways)
        d = _delta(-int128(uint128(expectedBuy + 1)), 1);
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.PartialFill.selector, expectedBuy, expectedBuy + 1));
        hook.afterSwap(address(swapper), key, _params(false, true, 1e18), d, "");

        // Case 4 at t=0: the pool produced less IMD than amountOut + base + surcharge -> PartialFill.
        uint256 expectedSell = 1e18 + fee + 1e18 * 2000 / BPS;
        d = _delta(int128(uint128(expectedSell - 1)), -1);
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.PartialFill.selector, expectedSell, expectedSell - 1));
        hook.afterSwap(address(swapper), key, _params(true, false, 1e18), d, "");
        // the surcharge is part of the expectation: after the window only the base fee is expected
        vm.warp(T0 + 1800);
        d = _delta(int128(uint128(expectedSell)), -1);
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.PartialFill.selector, 1e18 + fee, expectedSell));
        hook.afterSwap(address(swapper), key, _params(true, false, 1e18), d, "");
        vm.assertEq(hook.pending(), 0, "nothing minted on any revert");
    }

    // --------------------------------------- partial fills -------------------------------------- //

    /// @dev Case 1 through the manager: the pool runs out of MONEYBACK before amountIn - fee is
    ///      consumed. The whole swap reverts PartialFill, so the hook never keeps a fee on IMD
    ///      the pool did not move and the swapper keeps every wei.
    function test_partialFill_exactInputBuy_reverts() public {
        _initPool();
        uint256 amount = 1000e18;
        uint256 fee = amount * 425 / BPS;
        uint256 cap = 300e18;
        pm.setMaxOut(cap);
        uint256 imdBefore = imd.balanceOf(address(swapper));
        uint256 tokBefore = token.balanceOf(address(swapper));
        uint256 consumed = _poolInFor(cap);
        vm.assertTrue(consumed < amount - fee, "the cap binds");
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.PartialFill.selector, amount - fee, consumed));
        swapper.swap(key, _params(false, true, amount));
        vm.assertEq(hook.pending(), 0, "no fee kept on a reverted swap");
        vm.assertEq(imd.balanceOf(address(swapper)), imdBefore, "swapper IMD untouched");
        vm.assertEq(token.balanceOf(address(swapper)), tokBefore, "swapper MONEYBACK untouched");
        vm.assertFalse(pm.unlocked(), "lock released");
        // a cap that does not bind leaves the swap untouched
        pm.setMaxOut(amount);
        _swapAndCheck(false, true, amount, 0);
    }

    /// @dev Case 4 through the manager: the pool cannot produce amountOut + fee of IMD.
    function test_partialFill_exactOutputSell_reverts() public {
        _initPool();
        uint256 amount = 1000e18;
        uint256 feeT0 = amount * 425 / BPS + amount * 2000 / BPS;
        uint256 cap = 500e18;
        pm.setMaxOut(cap);
        uint256 imdBefore = imd.balanceOf(address(swapper));
        uint256 tokBefore = token.balanceOf(address(swapper));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.PartialFill.selector, amount + feeT0, cap));
        swapper.swap(key, _params(true, false, amount));
        vm.assertEq(hook.pending(), 0, "no fee kept on a reverted swap");
        vm.assertEq(imd.balanceOf(address(swapper)), imdBefore, "swapper IMD untouched");
        vm.assertEq(token.balanceOf(address(swapper)), tokBefore, "swapper MONEYBACK untouched");
        // the cap is exactly the gross amount: full fill, normal fee
        pm.setMaxOut(amount + feeT0);
        _swapAndCheck(true, false, amount, 0);
        // one wei short of the gross amount: partial, reverts
        pm.setMaxOut(amount + feeT0 - 1);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.PartialFill.selector, amount + feeT0, amount + feeT0 - 1));
        swapper.swap(key, _params(true, false, amount));
    }

    /// @dev Case 2 through the manager: the pool delivers less MONEYBACK than asked, so it takes
    ///      less IMD. The fee is 4.25% of the IMD actually moved, not of what a full fill would cost.
    function test_partialFill_exactOutputBuy_feesActualImd() public {
        _initPool();
        uint256 amount = 1000e18;
        uint256 cap = 250e18;
        pm.setMaxOut(cap);
        uint256 total = _swapAndCheck(false, false, amount, 0);
        uint256 poolImd = _poolInFor(cap);
        vm.assertEq(_abs(_imdDelta(pm.lastPoolDelta())), poolImd, "pool moved IMD for the capped output only");
        vm.assertEq(total, poolImd * 425 / BPS, "fee on the IMD actually moved");
        vm.assertTrue(total < _poolInFor(amount) * 425 / BPS, "strictly less than a full-fill fee");
        vm.assertEq(_abs(_tokenDelta(pm.lastPoolDelta())), cap, "swapper got the capped output");
    }

    /// @dev Case 3 through the manager: the pool delivers less IMD than the input is worth; the fee
    ///      and surcharge apply to the delivered IMD only.
    function test_partialFill_exactInputSell_feesActualImd() public {
        _initPool();
        vm.warp(T0 + 900);
        uint256 amount = 1000e18;
        uint256 cap = 400e18;
        pm.setMaxOut(cap);
        uint256 imdBefore = imd.balanceOf(address(swapper));
        uint256 total = _swapAndCheck(true, true, amount, 900);
        vm.assertEq(_abs(_imdDelta(pm.lastPoolDelta())), cap, "pool delivered the cap");
        vm.assertEq(total, cap * 425 / BPS + cap * 1000 / BPS, "base + surcharge on delivered IMD");
        vm.assertEq(imd.balanceOf(address(swapper)) - imdBefore, cap - total, "seller receives cap - take");
        // the seller only paid the MONEYBACK the capped output cost
        vm.assertEq(_abs(_tokenDelta(pm.lastPoolDelta())), _poolInFor(cap), "input consumed matches the cap");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_partialFill_allCases(uint256 amount, uint256 cap, uint256 elapsed, uint8 caseSel) public {
        _initPool();
        amount = _bound(amount, 1, 1e25);
        cap = _bound(cap, 1, 1e25);
        elapsed = _bound(elapsed, 0, 3600);
        bool isSell = caseSel & 1 == 1;
        bool exactInput = caseSel & 2 == 2;
        vm.warp(T0 + elapsed);
        pm.setMaxOut(cap);

        bool imdSpecified = exactInput ? !isSell : isSell;
        if (!imdSpecified) {
            // cases 2 and 3 always succeed and fee the IMD the pool actually moved (checked inside)
            uint256 total = _swapAndCheck(isSell, exactInput, amount, elapsed);
            uint256 poolImd = _abs(_imdDelta(pm.lastPoolDelta()));
            uint256 expected = poolImd * 425 / BPS + (isSell ? poolImd * _surchargeBps(elapsed) / BPS : 0);
            vm.assertEq(total, expected, "fee on moved IMD");
            return;
        }
        // cases 1 and 4: full fill behaves as before, a binding cap reverts PartialFill
        (bool binds, uint256 poolImdExpected, uint256 actual) = _capBinds(isSell, amount, cap, elapsed);
        if (!binds) {
            _swapAndCheck(isSell, exactInput, amount, elapsed);
            return;
        }
        _expectPartialFill(isSell, exactInput, amount, poolImdExpected, actual);
    }

    /// @dev For cases 1 and 4: whether `cap` stops the pool from moving the IMD the hook expects,
    ///      and the (expected, actual) pair PartialFill will carry.
    function _capBinds(bool isSell, uint256 amount, uint256 cap, uint256 elapsed)
        internal
        view
        returns (bool binds, uint256 poolImdExpected, uint256 actual)
    {
        uint256 fee = amount * 425 / BPS + (isSell ? amount * _surchargeBps(elapsed) / BPS : 0);
        poolImdExpected = isSell ? amount + fee : amount - fee;
        if (isSell) {
            binds = cap < poolImdExpected;
            actual = cap;
        } else {
            uint256 fullOut = poolImdExpected * (PIPS - LP_FEE) / PIPS;
            binds = cap < fullOut;
            actual = _poolInFor(cap);
        }
    }

    function _expectPartialFill(bool isSell, bool exactInput, uint256 amount, uint256 expected, uint256 actual)
        internal
    {
        uint256 pendingBefore = hook.pending();
        uint256 imdBefore = imd.balanceOf(address(swapper));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.PartialFill.selector, expected, actual));
        swapper.swap(key, _params(isSell, exactInput, amount));
        vm.assertEq(hook.pending(), pendingBefore, "nothing accrued on a partial fill");
        vm.assertEq(imd.balanceOf(address(swapper)), imdBefore, "swapper untouched");
        vm.assertFalse(pm.unlocked(), "lock released");
    }

    function test_tinySwapsRoundFeeDownToZero() public {
        _initPool();
        // 23 wei * 425 / 10000 = 0 (floor); 2000 bps surcharge on 23 wei = 4
        uint256 take = _swapAndCheck(false, true, 23, 0);
        vm.assertEq(take, 0, "fee rounds down to zero");
        take = _swapAndCheck(true, false, 23, 0);
        vm.assertEq(take, 23 * 2000 / BPS, "only the surcharge survives rounding");
        // 24 wei: base = 1
        take = _swapAndCheck(false, true, 24, 0);
        vm.assertEq(take, 1, "24 wei * 425 / 10000 = 1");
    }

    function test_oneWeiSwapsWork() public {
        _initPool();
        _swapAndCheck(false, true, 1, 0);
        _swapAndCheck(false, false, 1, 0);
        _swapAndCheck(true, true, 1, 0);
        _swapAndCheck(true, false, 1, 0);
    }

    function test_quoteFeesMatchesCallbacks() public {
        _initPool();
        vm.warp(T0 + 450);
        (uint256 b, uint256 s) = hook.quoteFees(true, 1e18);
        vm.assertEq(b, 1e18 * 425 / BPS, "quote base");
        vm.assertEq(s, 1e18 * _surchargeBps(450) / BPS, "quote surcharge");
        (b, s) = hook.quoteFees(false, 1e18);
        vm.assertEq(s, 0, "buy quote has no surcharge");
        vm.assertEq(hook.surchargeBpsAt(T0 + 450), _surchargeBps(450), "surchargeBpsAt");
        vm.assertEq(hook.surchargeBpsAt(T0 - 1), 0, "before init: zero");
        vm.assertEq(hook.surchargeBpsAt(T0 + 1800), 0, "at 1800: zero");
        vm.assertEq(hook.surchargeBpsAt(type(uint256).max), 0, "far future: zero");
    }

    // ------------------------------------------- sweep ------------------------------------------ //

    function test_emptySweepSucceeds() public {
        _initPool();
        vm.expectEmit(true, false, false, true, address(hook));
        emit MoneyBackHook.Swept(0, payout);
        hook.sweep();
        vm.assertEq(imd.balanceOf(payout), 0, "nothing moved");
        // also before the pool is bound (different payout so the CREATE2 address differs)
        MoneyBackHook fresh = _deployHook(address(pm), address(token), address(0xD00D));
        vm.expectEmit(true, false, false, true, address(fresh));
        emit MoneyBackHook.Swept(0, address(0xD00D));
        fresh.sweep();
    }

    function test_sweepPaysOnlyPayoutAndClearsPending() public {
        _initPool();
        uint256 t1 = _swapAndCheck(true, true, 5000e18, 0);
        uint256 t2 = _swapAndCheck(false, false, 3000e18, 0);
        uint256 pendingBefore = hook.pending();
        vm.assertEq(pendingBefore, t1 + t2, "pending sums takes");
        uint256 pmImd = imd.balanceOf(address(pm));

        vm.prank(address(0xCAFE)); // permissionless
        vm.expectEmit(true, false, false, true, address(hook));
        emit MoneyBackHook.Swept(pendingBefore, payout);
        hook.sweep();

        vm.assertEq(hook.pending(), 0, "pending cleared");
        vm.assertEq(imd.balanceOf(payout), pendingBefore, "payout received everything");
        vm.assertEq(imd.balanceOf(address(pm)), pmImd - pendingBefore, "manager paid it out");
        vm.assertEq(imd.balanceOf(address(hook)), 0, "hook holds no IMD");
        vm.assertEq(imd.balanceOf(address(0xCAFE)), 0, "caller got nothing");
        vm.assertEq(pm.balanceOf(address(hook), uint256(uint160(IMD))), 0, "claims burnt");
        vm.assertFalse(pm.unlocked(), "lock released");
        // second sweep is a no-op
        hook.sweep();
        vm.assertEq(imd.balanceOf(payout), pendingBefore, "no double pay");
    }

    function test_sweepTakesDonatedClaimsToo() public {
        _initPool();
        // a stranger hands the hook IMD claims directly (ERC-6909 transfer): pending() counts them
        // and sweep() still sends everything to payout, never elsewhere.
        pm.unlockedForTest(true);
        pm.sync(Currency.wrap(IMD));
        imd.mint(address(pm), 7e18);
        pm.settle();
        pm.mint(address(this), uint256(uint160(IMD)), 7e18);
        pm.unlockedForTest(false);
        pm.transfer(address(hook), uint256(uint160(IMD)), 7e18);
        vm.assertEq(hook.pending(), 7e18, "donated claims count as pending");
        hook.sweep();
        vm.assertEq(imd.balanceOf(payout), 7e18, "swept to payout");
        vm.assertEq(hook.pending(), 0, "cleared");
    }

    function test_unlockCallbackOnlyDuringSweep() public {
        _initPool();
        _swapAndCheck(false, true, 100e18, 0);
        vm.prank(address(pm));
        vm.expectRevert(MoneyBackHook.UnexpectedCallback.selector);
        hook.unlockCallback("");
        vm.assertEq(imd.balanceOf(payout), 0, "nothing moved");
    }

    function test_sweepReentrancyBlocked() public {
        // Re-enter sweep() from inside the PoolManager unlock: the PoolManager is a stranger here,
        // but the guard must trip before any manager call.
        _initPool();
        _swapAndCheck(false, true, 100e18, 0);
        ReenteringManagerProbe probe = new ReenteringManagerProbe(hook);
        MoneyBackHook h2 = _deployHook(address(probe), address(token), payout);
        probe.setHook(h2);
        vm.expectRevert(MoneyBackHook.Reentrancy.selector);
        h2.sweep();
    }

    function test_noOtherWayToMoveFunds() public {
        _initPool();
        _swapAndCheck(false, true, 100e18, 0);
        uint256 pendingBefore = hook.pending();
        // Nobody but the hook can burn or take its claims through the manager (burn requires
        // from == msg.sender), and the hook exposes no transfer path.
        pm.unlockedForTest(true);
        vm.expectRevert(bytes("not operator"));
        pm.burn(address(hook), uint256(uint160(IMD)), pendingBefore);
        pm.unlockedForTest(false);
        vm.assertEq(hook.pending(), pendingBefore, "untouched");
    }

    // ------------------------------------------- fuzz ------------------------------------------- //

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_feeFormulaAllCases(uint256 amount, uint256 elapsed, uint8 caseSel) public {
        _initPool();
        amount = _bound(amount, 1, 1e25);
        elapsed = _bound(elapsed, 0, 30 days);
        bool isSell = caseSel & 1 == 1;
        bool exactInput = caseSel & 2 == 2;
        vm.warp(T0 + elapsed);
        _swapAndCheck(isSell, exactInput, amount, elapsed);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_surchargeFormula(uint256 elapsed) public {
        _initPool();
        elapsed = _bound(elapsed, 0, 365 days);
        vm.warp(T0 + elapsed);
        uint256 expected = elapsed >= 1800 ? 0 : 2000 * (1800 - elapsed) / 1800;
        vm.assertEq(hook.currentSurchargeBps(), expected, "surcharge formula");
        vm.assertLe(hook.currentSurchargeBps(), 2000, "never above start");
        if (elapsed >= 1800) vm.assertEq(hook.currentSurchargeBps(), 0, "zero after the window");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_sweepAfterSwaps(uint256 a, uint256 b, uint256 elapsed) public {
        _initPool();
        a = _bound(a, 1, 1e24);
        b = _bound(b, 1, 1e24);
        elapsed = _bound(elapsed, 0, 3600);
        vm.warp(T0 + elapsed);
        uint256 t1 = _swapAndCheck(true, true, a, elapsed);
        uint256 t2 = _swapAndCheck(false, true, b, elapsed);
        uint256 t3 = _swapAndCheck(true, false, a, elapsed);
        uint256 t4 = _swapAndCheck(false, false, b, elapsed);
        uint256 expected = t1 + t2 + t3 + t4;
        vm.assertEq(hook.pending(), expected, "pending == sum of takes");
        hook.sweep();
        vm.assertEq(hook.pending(), 0, "swept");
        vm.assertEq(imd.balanceOf(payout), expected, "payout got all");
    }
}

/// @dev A fake manager whose unlock() re-enters hook.sweep() instead of calling back.
contract ReenteringManagerProbe {
    MoneyBackHook public hook;

    constructor(MoneyBackHook h) {
        hook = h;
    }

    function setHook(MoneyBackHook h) external {
        hook = h;
    }

    function unlock(bytes calldata) external returns (bytes memory) {
        hook.sweep(); // must revert Reentrancy
        return "";
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

// ============================================================================================= //
//                                           invariants                                          //
// ============================================================================================= //

contract HookHandler is TestBase {
    using DeltaLib for BalanceDelta;

    MoneyBackHook public hook;
    MockPoolManager public pm;
    MockERC20 public imd;
    MoneyBackToken public token;
    Swapper public swapper;
    PoolKey public key;
    address public payout;
    bool internal imdIs0;

    bytes32 internal constant FEE_ACCRUED_SIG = keccak256("FeeAccrued(bool,uint256,uint256,uint256)");
    bytes32 internal constant SWEPT_SIG = keccak256("Swept(uint256,address)");

    uint256 public ghostAccrued;
    uint256 public ghostSwept;
    uint256 public ghostSweptToOther;
    uint256 public ghostSwaps;
    uint256 public ghostSweeps;
    uint256 public ghostFormulaViolations;
    uint256 public ghostImdSwapperNet; // not used for assertions, kept for debugging
    uint256 public initializedAt;

    constructor(
        MoneyBackHook hook_,
        MockPoolManager pm_,
        MockERC20 imd_,
        MoneyBackToken token_,
        Swapper swapper_,
        PoolKey memory key_,
        address payout_
    ) {
        hook = hook_;
        pm = pm_;
        imd = imd_;
        token = token_;
        swapper = swapper_;
        key = key_;
        payout = payout_;
        imdIs0 = hook_.imdIsCurrency0();
        initializedAt = hook_.initializedAt();
    }

    uint256 public ghostPartialFillReverts;
    uint256 public ghostUnexpectedReverts;

    function _swap(bool isSell, bool exactInput, uint256 amount) internal {
        amount = _bound(amount, 1, 1e24);
        bool zeroForOne = isSell ? !imdIs0 : imdIs0;
        SwapParams memory p = SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), 0);
        uint256 pendingBefore = hook.pending();
        vm.recordLogs();
        try swapper.swap(key, p) {}
        catch (bytes memory err) {
            // The only revert a swap may hit is PartialFill, and only when IMD is the specified
            // currency (cases 1 and 4) while the liquidity cap binds. A reverted swap accrues nothing.
            bool imdSpecified = exactInput ? !isSell : isSell;
            if (bytes4(err) == MoneyBackHook.PartialFill.selector && imdSpecified && pm.maxOut() != 0) {
                ghostPartialFillReverts += 1;
            } else {
                ghostUnexpectedReverts += 1;
            }
            if (hook.pending() != pendingBefore) ghostUnexpectedReverts += 1;
            vm.getRecordedLogs();
            ghostSwaps += 1;
            return;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 elapsed = block.timestamp - initializedAt;
        uint256 bps = elapsed >= 1800 ? 0 : 2000 * (1800 - elapsed) / 1800;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEE_ACCRUED_SIG) {
                (uint256 base, uint256 surcharge, uint256 leg) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                ghostAccrued += base + surcharge;
                bool sell = uint256(logs[i].topics[1]) == 1;
                if (base != leg * 425 / 10_000) ghostFormulaViolations += 1;
                if (surcharge != (sell ? leg * bps / 10_000 : 0)) ghostFormulaViolations += 1;
                if (sell != isSell) ghostFormulaViolations += 1;
            }
        }
        ghostSwaps += 1;
    }

    function buyExactIn(uint256 amount) external {
        _swap(false, true, amount);
    }

    function buyExactOut(uint256 amount) external {
        _swap(false, false, amount);
    }

    function sellExactIn(uint256 amount) external {
        _swap(true, true, amount);
    }

    function sellExactOut(uint256 amount) external {
        _swap(true, false, amount);
    }

    function warp(uint256 delta) external {
        delta = _bound(delta, 0, 600);
        vm.warp(block.timestamp + delta);
    }

    /// @dev Toggles the pool's liquidity cap so later swaps may be partial fills (0 = full fills).
    function setLiquidityCap(uint256 seed) external {
        uint256 cap = seed % 3 == 0 ? 0 : _bound(seed, 1, 1e23);
        pm.setMaxOut(cap);
    }

    function sweep(uint256 callerSeed) external {
        address caller = address(uint160(_bound(callerSeed, 1, type(uint160).max)));
        vm.recordLogs();
        vm.prank(caller);
        hook.sweep();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == SWEPT_SIG) {
                uint256 amount = abi.decode(logs[i].data, (uint256));
                address to = address(uint160(uint256(logs[i].topics[1])));
                if (to == payout) ghostSwept += amount;
                else ghostSweptToOther += amount;
            }
        }
        ghostSweeps += 1;
    }
}

contract MoneyBackHookInvariantTest is HookFixture {
    HookHandler internal handler;
    uint256 internal imdTotalMinted;

    function setUp() public {
        _setUpFixture();
        _initPool();
        handler = new HookHandler(hook, pm, imd, token, swapper, key, payout);
        imdTotalMinted = imd.totalSupply();
    }

    function targetContracts() public view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(handler);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_pendingEqualsAccruedMinusSwept() public view {
        vm.assertEq(hook.pending(), handler.ghostAccrued() - handler.ghostSwept(), "pending == accrued - swept");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_hookNeverHoldsMoneyBack() public view {
        vm.assertEq(pm.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "no MONEYBACK claims");
        vm.assertEq(token.balanceOf(address(hook)), 0, "no MONEYBACK tokens");
        vm.assertEq(imd.balanceOf(address(hook)), 0, "no IMD tokens outside the manager");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_sweepPaysOnlyPayout() public view {
        vm.assertEq(handler.ghostSweptToOther(), 0, "never swept elsewhere");
        vm.assertEq(imd.balanceOf(payout), handler.ghostSwept(), "payout balance == swept");
        // conservation: IMD lives only in the manager, the swapper and payout
        vm.assertEq(
            imd.balanceOf(address(pm)) + imd.balanceOf(address(swapper)) + imd.balanceOf(payout),
            imdTotalMinted,
            "IMD conserved"
        );
        vm.assertGe(imd.balanceOf(address(pm)), hook.pending(), "claims are backed");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_feeFormulasAndLockState() public view {
        vm.assertEq(handler.ghostFormulaViolations(), 0, "every FeeAccrued matched the formula");
        vm.assertEq(handler.ghostUnexpectedReverts(), 0, "only PartialFill in cases 1/4 under a binding cap reverts");
        vm.assertFalse(pm.unlocked(), "manager never left unlocked");
        vm.assertEq(pm.nonzeroDeltaCount(), 0, "no dangling deltas");
        vm.assertEq(hook.initializedAt(), T0, "binding never changes");
        vm.assertEq(token.totalSupply(), 1_000_000_000e18, "supply fixed");
    }
}
