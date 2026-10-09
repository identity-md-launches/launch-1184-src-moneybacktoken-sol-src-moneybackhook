// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal ERC20 surface used by RoundPayout.
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title RoundPayout: token-agnostic batch payer driven by the IMD Money Back engine
/// @notice The only privileged contract of the launch. The owner (the engine) pays each 15-minute
///         round as one batch; anyone can fund it. Ownable2Step, ReentrancyGuard, Pausable and
///         SafeERC20 are implemented inline with OpenZeppelin v5 semantics (same function names,
///         events and custom errors) because the launch build vendors no libraries.
///
///         TRUST ASSUMPTIONS: the owner chooses the token, recipients and amounts of every round
///         and can sweep any balance. Pausing blocks payRound and retryFailed. The contract never
///         holds a privileged position over the hook or the token: funds reach it only by `fund`
///         or by the hook's `sweep()` when it is the hook's payout address.
contract RoundPayout {
    // ----------------------------------------------------------------------------------------- //
    //                                             types                                          //
    // ----------------------------------------------------------------------------------------- //

    struct Round {
        address token; // token the round was paid in
        uint256 paidAt; // block.timestamp of payRound; non-zero == paid
        uint256 count; // number of legs in the batch
        uint256 failedCount; // recipients with a non-zero failed[roundId][to] entry
        bytes32 ledgerHash; // engine's ledger commitment
        uint256 totalPaid; // sum of successful legs (initial batch + retries)
    }

    // ----------------------------------------------------------------------------------------- //
    //                                           constants                                        //
    // ----------------------------------------------------------------------------------------- //

    /// @notice Maximum legs per round. Invariant: to.length == amounts.length <= MAX_BATCH.
    uint256 public constant MAX_BATCH = 500;

    // ----------------------------------------------------------------------------------------- //
    //                                             state                                          //
    // ----------------------------------------------------------------------------------------- //

    address private _owner;
    address private _pendingOwner;
    bool private _paused;
    uint256 private _reentrancyStatus = 1; // 1 = not entered, 2 = entered

    /// @notice Round bookkeeping: rounds(roundId) -> (token, paidAt, count, failedCount, ledgerHash, totalPaid).
    mapping(uint256 roundId => Round) public rounds;
    /// @notice Outstanding failed amount per (round, recipient); 0 once retried successfully or written off.
    mapping(uint256 roundId => mapping(address to => uint256 amount)) public failed;

    // ----------------------------------------------------------------------------------------- //
    //                                             events                                         //
    // ----------------------------------------------------------------------------------------- //

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);

    event Funded(address indexed token, address indexed from, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event Paid(uint256 indexed roundId, address indexed to, uint256 amount);
    event PayFailed(uint256 indexed roundId, address indexed to, uint256 amount, bytes reason);
    event WrittenOff(uint256 indexed roundId, address indexed to, uint256 amount);
    event RoundPaid(
        uint256 indexed roundId,
        address indexed token,
        bytes32 ledgerHash,
        uint256 twapCloseX96,
        uint256 totalEligibleLoss,
        uint256 totalPaid,
        uint256 count
    );

    // ----------------------------------------------------------------------------------------- //
    //                                             errors                                         //
    // ----------------------------------------------------------------------------------------- //

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    error EnforcedPause();
    error ExpectedPause();
    error ReentrancyGuardReentrantCall();
    error SafeERC20FailedOperation(address token);

    error RoundAlreadyPaid(uint256 roundId);
    error RoundNotPaid(uint256 roundId);
    error LengthMismatch();
    error BatchTooLarge();
    error EmptyBatch();
    error InsufficientBalance(uint256 required, uint256 available);
    error AllTransfersFailed();
    error NothingFailed(uint256 roundId, address to);
    error InvalidAddress();

    // ----------------------------------------------------------------------------------------- //
    //                                           modifiers                                        //
    // ----------------------------------------------------------------------------------------- //

    modifier onlyOwner() {
        if (msg.sender != _owner) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert EnforcedPause();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus == 2) revert ReentrancyGuardReentrantCall();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    // ----------------------------------------------------------------------------------------- //
    //                                          constructor                                       //
    // ----------------------------------------------------------------------------------------- //

    /// @param initialOwner The engine's owner key ($owner).
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _transferOwnership(initialOwner);
    }

    // ----------------------------------------------------------------------------------------- //
    //                                         Ownable2Step                                       //
    // ----------------------------------------------------------------------------------------- //

    function owner() public view returns (address) {
        return _owner;
    }

    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    /// @notice Step 1 of 2: nominate `newOwner`; they must call acceptOwnership().
    function transferOwnership(address newOwner) external onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    /// @notice Step 2 of 2: the nominated owner takes over.
    function acceptOwnership() external {
        if (msg.sender != _pendingOwner) revert OwnableUnauthorizedAccount(msg.sender);
        _transferOwnership(msg.sender);
    }

    /// @notice Leaves the contract without an owner: nobody can pay rounds, sweep or pause afterwards.
    function renounceOwnership() external onlyOwner {
        _transferOwnership(address(0));
    }

    function _transferOwnership(address newOwner) internal {
        delete _pendingOwner;
        address previous = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }

    // ----------------------------------------------------------------------------------------- //
    //                                            Pausable                                        //
    // ----------------------------------------------------------------------------------------- //

    function paused() public view returns (bool) {
        return _paused;
    }

    function pause() external onlyOwner {
        if (_paused) revert EnforcedPause();
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!_paused) revert ExpectedPause();
        _paused = false;
        emit Unpaused(msg.sender);
    }

    // ----------------------------------------------------------------------------------------- //
    //                                             views                                          //
    // ----------------------------------------------------------------------------------------- //

    /// @notice True once payRound(roundId, ...) has completed.
    function isPaid(uint256 roundId) public view returns (bool) {
        return rounds[roundId].paidAt != 0;
    }

    // ----------------------------------------------------------------------------------------- //
    //                                            funding                                         //
    // ----------------------------------------------------------------------------------------- //

    /// @notice Anyone may top up the contract with `amount` of `token` (requires prior approval).
    function fund(address token, uint256 amount) external {
        _safeTransferFrom(token, msg.sender, address(this), amount);
        emit Funded(token, msg.sender, amount);
    }

    /// @notice Owner withdraws `amount` of `token` to `to`.
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        _safeTransfer(token, to, amount);
        emit Swept(token, to, amount);
    }

    // ----------------------------------------------------------------------------------------- //
    //                                            payouts                                         //
    // ----------------------------------------------------------------------------------------- //

    /// @notice Pays one round as a batch of `token` transfers.
    /// @dev Reverts RoundAlreadyPaid if the round id was used; LengthMismatch / BatchTooLarge /
    ///      EmptyBatch on bad shapes; InsufficientBalance up front if sum(amounts) exceeds the
    ///      contract's token balance. A leg whose transfer reverts, returns false or runs out of
    ///      gas is recorded in failed[roundId][to] (amounts accumulate for a repeated recipient;
    ///      rounds(roundId).failedCount counts recipients with an outstanding entry, not legs),
    ///      emitted as PayFailed, and the batch continues. AllTransfersFailed reverts the whole
    ///      call only when every leg failed. The round is marked paid after the loop.
    ///      Invariants: totalPaid == sum(Paid amounts) for the round, which never exceeds
    ///      sum(amounts); sum of all Paid amounts over the contract's life never exceeds what
    ///      was funded into it.
    /// @return totalPaid Sum of the legs that succeeded (failed legs excluded).
    function payRound(
        uint256 roundId,
        address token,
        address[] calldata to,
        uint256[] calldata amounts,
        bytes32 ledgerHash,
        uint256 twapCloseX96,
        uint256 totalEligibleLoss
    ) external onlyOwner whenNotPaused nonReentrant returns (uint256 totalPaid) {
        if (isPaid(roundId)) revert RoundAlreadyPaid(roundId);
        uint256 n = to.length;
        if (n != amounts.length) revert LengthMismatch();
        if (n > MAX_BATCH) revert BatchTooLarge();
        if (n == 0) revert EmptyBatch();
        _checkBalance(token, amounts);

        {
            uint256 failedLegs;
            (totalPaid, failedLegs) = _payLegs(roundId, token, to, amounts);
            if (failedLegs == n) revert AllTransfersFailed();
        }
        {
            Round storage round = rounds[roundId];
            round.token = token;
            round.paidAt = block.timestamp;
            round.count = n;
            round.ledgerHash = ledgerHash;
            round.totalPaid = totalPaid;
        }
        emit RoundPaid(roundId, token, ledgerHash, twapCloseX96, totalEligibleLoss, totalPaid, n);
    }

    /// @notice Re-sends the stored failed amounts of `roundId` to each `to`. A leg that succeeds is
    ///         cleared, counted in totalPaid and emitted as Paid; one that fails again stays stored
    ///         and is emitted as PayFailed. A recipient with nothing stored (never failed, already
    ///         retried, written off, or listed twice in `to`) is skipped so one such entry never
    ///         rolls back the legs already re-sent in the same call.
    function retryFailed(uint256 roundId, address[] calldata to) external onlyOwner whenNotPaused nonReentrant {
        Round storage round = rounds[roundId];
        if (round.paidAt == 0) revert RoundNotPaid(roundId);
        address token = round.token;
        for (uint256 i; i < to.length; ++i) {
            uint256 amount = failed[roundId][to[i]];
            if (amount == 0) continue;
            (bool ok, bytes memory reason) = _tryTransfer(token, to[i], amount);
            if (ok) {
                delete failed[roundId][to[i]];
                round.failedCount -= 1;
                round.totalPaid += amount;
                emit Paid(roundId, to[i], amount);
            } else {
                emit PayFailed(roundId, to[i], amount, reason);
            }
        }
    }

    /// @notice Clears a stored failed leg without paying it.
    function writeOffFailed(uint256 roundId, address to) external onlyOwner {
        uint256 amount = failed[roundId][to];
        if (amount == 0) revert NothingFailed(roundId, to);
        delete failed[roundId][to];
        rounds[roundId].failedCount -= 1;
        emit WrittenOff(roundId, to, amount);
    }

    // ----------------------------------------------------------------------------------------- //
    //                                           internals                                        //
    // ----------------------------------------------------------------------------------------- //

    /// @dev Reverts InsufficientBalance if sum(amounts) exceeds this contract's balance of `token`.
    function _checkBalance(address token, uint256[] calldata amounts) internal view {
        uint256 required;
        for (uint256 i; i < amounts.length; ++i) {
            required += amounts[i];
        }
        uint256 available = IERC20(token).balanceOf(address(this));
        if (required > available) revert InsufficientBalance(required, available);
    }

    /// @dev Pays every leg, recording failures instead of reverting.
    /// @return totalPaid Sum of successful legs.
    /// @return failedLegs Number of legs that failed (duplicated recipients count once per leg).
    ///         rounds[roundId].failedCount is incremented for every distinct recipient stored.
    function _payLegs(uint256 roundId, address token, address[] calldata to, uint256[] calldata amounts)
        internal
        returns (uint256 totalPaid, uint256 failedLegs)
    {
        for (uint256 i; i < to.length; ++i) {
            (bool ok, bytes memory reason) = _tryTransfer(token, to[i], amounts[i]);
            if (ok) {
                totalPaid += amounts[i];
                emit Paid(roundId, to[i], amounts[i]);
            } else {
                ++failedLegs;
                if (failed[roundId][to[i]] == 0 && amounts[i] != 0) rounds[roundId].failedCount += 1;
                failed[roundId][to[i]] += amounts[i];
                emit PayFailed(roundId, to[i], amounts[i], reason);
            }
        }
    }

    /// @dev Low-level try of token.transfer(to, amount). Success means the call did not revert,
    ///      the token has code, and it returned either nothing or `true`. Never reverts itself.
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool ok, bytes memory reason) {
        if (to == address(0)) return (false, bytes("zero recipient"));
        if (token.code.length == 0) return (false, bytes("token has no code"));
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!success) return (false, data);
        if (data.length == 0) return (true, "");
        if (data.length >= 32 && _firstWord(data) == 1) return (true, "");
        return (false, bytes("transfer returned false"));
    }

    /// @dev SafeERC20.safeTransfer semantics: reverts SafeERC20FailedOperation unless the call
    ///      succeeds and returns nothing or `true`.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok,) = _tryTransfer(token, to, amount);
        if (!ok) revert SafeERC20FailedOperation(token);
    }

    /// @dev SafeERC20.safeTransferFrom semantics.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (token.code.length == 0) revert SafeERC20FailedOperation(token);
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!success || (data.length != 0 && !(data.length >= 32 && _firstWord(data) == 1))) {
            revert SafeERC20FailedOperation(token);
        }
    }

    /// @dev First 32-byte word of return data, read without ABI validation (a value other than
    ///      0/1 is a failure, not a revert of the whole batch).
    function _firstWord(bytes memory data) private pure returns (uint256 word) {
        assembly ("memory-safe") {
            word := mload(add(data, 0x20))
        }
    }
}
