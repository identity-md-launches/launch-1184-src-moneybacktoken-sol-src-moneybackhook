// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RoundPayout} from "src/RoundPayout.sol";
import {MoneyBackToken} from "src/MoneyBackToken.sol";

// ============================================================================================= //
//  Self-contained harness (the project vendors no libraries, so no forge-std).                   //
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
    function label(address, string calldata) external;
    function assume(bool) external pure;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool) external;
    function expectEmit(bool, bool, bool, bool, address) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function assertEq(uint256, uint256, string calldata) external pure;
    function assertEq(address, address, string calldata) external pure;
    function assertEq(bytes32, bytes32, string calldata) external pure;
    function assertEq(bytes calldata, bytes calldata, string calldata) external pure;
    function assertEq(bool, bool, string calldata) external pure;
    function assertTrue(bool, string calldata) external pure;
    function assertFalse(bool, string calldata) external pure;
    function assertLe(uint256, uint256, string calldata) external pure;
    function assertGe(uint256, uint256, string calldata) external pure;
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

/// @dev ERC20 whose transfer() misbehaves per recipient / per mode, to drive the failure paths.
///      Modes per recipient: 0 normal, 1 revert with reason, 2 return false, 3 burn all gas,
///      4 return nothing (USDT style, success), 5 return garbage word, 6 revert with no data.
contract FlakyToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint8) public mode;
    bool public transferFromReturnsFalse;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setMode(address to, uint8 m) external {
        mode[to] = m;
    }

    function setTransferFromReturnsFalse(bool v) external {
        transferFromReturnsFalse = v;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (transferFromReturnsFalse) return false;
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint8 m = mode[to];
        if (m == 1) revert("blocked recipient");
        if (m == 2) return false;
        if (m == 3) {
            while (true) {}
        }
        if (m == 6) {
            assembly {
                revert(0, 0)
            }
        }
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        if (m == 4) {
            assembly {
                return(0, 0)
            }
        }
        if (m == 5) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return true;
    }
}

/// @dev Token whose transfer re-enters the payer with a chosen call, to prove the guard.
contract ReentrantToken {
    mapping(address => uint256) public balanceOf;
    RoundPayout public target;
    bytes public reentryCall;
    bytes public lastReentryError;
    bool public reentrySucceeded;
    uint256 public reentries;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(RoundPayout t, bytes calldata call) external {
        target = t;
        reentryCall = call;
    }

    /// @dev Forwards a call so the token can act as the payer's owner.
    function exec(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (reentryCall.length != 0 && reentries == 0) {
            reentries += 1;
            (bool ok, bytes memory err) = address(target).call(reentryCall);
            reentrySucceeded = ok;
            lastReentryError = err;
            // keep the record (no revert) and fail this leg without moving funds
            if (!ok) return false;
        }
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ============================================================================================= //
//                                            fixture                                            //
// ============================================================================================= //

abstract contract PayoutFixture is TestBase {
    address internal owner = address(0xA11CE);
    address internal stranger = address(0xB0B);
    address internal alice = address(0x1001);
    address internal bob = address(0x1002);
    address internal carol = address(0x1003);

    RoundPayout internal payer;
    FlakyToken internal token;

    bytes32 internal constant PAID_SIG = keccak256("Paid(uint256,address,uint256)");
    bytes32 internal constant PAY_FAILED_SIG = keccak256("PayFailed(uint256,address,uint256,bytes)");

    function _setUpFixture() internal {
        vm.warp(1_700_000_000);
        payer = new RoundPayout(owner);
        token = new FlakyToken();
        token.mint(address(this), 1_000_000e18);
        token.approve(address(payer), type(uint256).max);
        vm.label(address(payer), "RoundPayout");
    }

    function _fund(uint256 amount) internal {
        payer.fund(address(token), amount);
    }

    function _arr3(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _amt3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _arr1(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _amt1(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _pay(uint256 roundId, address[] memory to, uint256[] memory amounts) internal returns (uint256) {
        vm.prank(owner);
        return payer.payRound(roundId, address(token), to, amounts, bytes32(uint256(roundId)), 1 << 96, 123e18);
    }

    function _round(uint256 roundId)
        internal
        view
        returns (address t, uint256 paidAt, uint256 count, uint256 failedCount, bytes32 ledgerHash, uint256 totalPaid)
    {
        return payer.rounds(roundId);
    }
}

// ============================================================================================= //
//                                          unit tests                                           //
// ============================================================================================= //

contract RoundPayoutTest is PayoutFixture {
    function setUp() public {
        _setUpFixture();
    }

    // ------------------------------------ constructor / ownership --------------------------------- //

    function test_constructorSetsOwnerAndRejectsZero() public {
        vm.assertEq(payer.owner(), owner, "owner");
        vm.assertEq(payer.pendingOwner(), address(0), "no pending owner");
        vm.assertFalse(payer.paused(), "not paused");
        vm.assertEq(payer.MAX_BATCH(), 500, "max batch");
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableInvalidOwner.selector, address(0)));
        new RoundPayout(address(0));
    }

    function test_ownable2StepHandoff() public {
        address newOwner = address(0xC0DE);
        // only the owner can nominate
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payer.transferOwnership(newOwner);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.OwnershipTransferStarted(owner, newOwner);
        payer.transferOwnership(newOwner);
        vm.assertEq(payer.owner(), owner, "owner unchanged until accepted");
        vm.assertEq(payer.pendingOwner(), newOwner, "pending set");

        // nobody but the nominee can accept, including the current owner
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payer.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, owner));
        payer.acceptOwnership();

        vm.prank(newOwner);
        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.OwnershipTransferred(owner, newOwner);
        payer.acceptOwnership();
        vm.assertEq(payer.owner(), newOwner, "handed off");
        vm.assertEq(payer.pendingOwner(), address(0), "pending cleared");

        // the old owner has lost every privilege
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, owner));
        payer.pause();
        vm.prank(newOwner);
        payer.pause();
        vm.assertTrue(payer.paused(), "new owner can pause");
    }

    function test_transferOwnershipToZeroCancelsPending() public {
        vm.prank(owner);
        payer.transferOwnership(stranger);
        vm.prank(owner);
        payer.transferOwnership(address(0));
        vm.assertEq(payer.pendingOwner(), address(0), "cancelled");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payer.acceptOwnership();
    }

    function test_renounceOwnershipLeavesNobodyInCharge() public {
        vm.prank(owner);
        payer.transferOwnership(stranger);
        vm.prank(owner);
        payer.renounceOwnership();
        vm.assertEq(payer.owner(), address(0), "no owner");
        vm.assertEq(payer.pendingOwner(), address(0), "pending wiped");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payer.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, owner));
        payer.pause();
    }

    // ----------------------------------------- pausing ------------------------------------------ //

    function test_pauseUnpauseStatesAndAccess() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payer.pause();
        vm.prank(owner);
        vm.expectRevert(RoundPayout.ExpectedPause.selector);
        payer.unpause();

        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(payer));
        emit RoundPayout.Paused(owner);
        payer.pause();
        vm.assertTrue(payer.paused(), "paused");
        vm.prank(owner);
        vm.expectRevert(RoundPayout.EnforcedPause.selector);
        payer.pause();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payer.unpause();
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(payer));
        emit RoundPayout.Unpaused(owner);
        payer.unpause();
        vm.assertFalse(payer.paused(), "unpaused");
    }

    function test_pauseBlocksPayRoundAndRetryButNotFundSweepWriteOff() public {
        _fund(100e18);
        token.setMode(bob, 1);
        _pay(1, _arr3(alice, bob, carol), _amt3(10e18, 20e18, 30e18));
        vm.prank(owner);
        payer.pause();

        vm.prank(owner);
        vm.expectRevert(RoundPayout.EnforcedPause.selector);
        payer.payRound(2, address(token), _arr1(alice), _amt1(1e18), bytes32(0), 0, 0);
        vm.prank(owner);
        vm.expectRevert(RoundPayout.EnforcedPause.selector);
        payer.retryFailed(1, _arr1(bob));

        // funding, owner sweep and write-off still work while paused
        payer.fund(address(token), 1e18);
        vm.prank(owner);
        payer.sweep(address(token), owner, 1e18);
        vm.prank(owner);
        payer.writeOffFailed(1, bob);
        vm.assertEq(payer.failed(1, bob), 0, "written off while paused");

        vm.prank(owner);
        payer.unpause();
        _pay(2, _arr1(alice), _amt1(1e18));
        vm.assertTrue(payer.isPaid(2), "works again after unpause");
    }

    // ------------------------------------------ fund -------------------------------------------- //

    function test_fundPullsTokensAndEmits() public {
        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.Funded(address(token), address(this), 5e18);
        payer.fund(address(token), 5e18);
        vm.assertEq(token.balanceOf(address(payer)), 5e18, "funded");
        // anyone may fund
        token.mint(stranger, 1e18);
        vm.prank(stranger);
        token.approve(address(payer), 1e18);
        vm.prank(stranger);
        payer.fund(address(token), 1e18);
        vm.assertEq(token.balanceOf(address(payer)), 6e18, "stranger funded");
    }

    function test_fundRevertsOnFailedPull() public {
        vm.prank(stranger); // no balance, no approval -> token reverts -> SafeERC20FailedOperation
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.SafeERC20FailedOperation.selector, address(token)));
        payer.fund(address(token), 1);
        // token returning false
        token.setTransferFromReturnsFalse(true);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.SafeERC20FailedOperation.selector, address(token)));
        payer.fund(address(token), 1);
        // token with no code
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.SafeERC20FailedOperation.selector, address(0xDEAD)));
        payer.fund(address(0xDEAD), 1);
    }

    // ------------------------------------------ sweep ------------------------------------------- //

    function test_sweepOwnerOnlyAndAccounting() public {
        _fund(10e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payer.sweep(address(token), stranger, 1e18);
        vm.prank(owner);
        vm.expectRevert(RoundPayout.InvalidAddress.selector);
        payer.sweep(address(token), address(0), 1e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.SafeERC20FailedOperation.selector, address(token)));
        payer.sweep(address(token), owner, 10e18 + 1);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.Swept(address(token), owner, 4e18);
        payer.sweep(address(token), owner, 4e18);
        vm.assertEq(token.balanceOf(owner), 4e18, "owner received");
        vm.assertEq(token.balanceOf(address(payer)), 6e18, "remaining");
        // sweep to a recipient whose transfer returns false reverts rather than silently failing
        token.setMode(carol, 2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.SafeERC20FailedOperation.selector, address(token)));
        payer.sweep(address(token), carol, 1e18);
    }

    // ---------------------------------------- payRound ------------------------------------------ //

    function test_payRoundHappyPath() public {
        _fund(100e18);
        address[] memory to = _arr3(alice, bob, carol);
        uint256[] memory amounts = _amt3(10e18, 20e18, 30e18);

        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.Paid(7, alice, 10e18);
        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.Paid(7, bob, 20e18);
        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.Paid(7, carol, 30e18);
        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.RoundPaid(7, address(token), bytes32(uint256(7)), 1 << 96, 123e18, 60e18, 3);
        uint256 totalPaid = _pay(7, to, amounts);

        vm.assertEq(totalPaid, 60e18, "totalPaid");
        vm.assertTrue(payer.isPaid(7), "paid");
        vm.assertFalse(payer.isPaid(8), "other round unpaid");
        (address t, uint256 paidAt, uint256 count, uint256 failedCount, bytes32 ledgerHash, uint256 tp) = _round(7);
        vm.assertEq(t, address(token), "round token");
        vm.assertEq(paidAt, block.timestamp, "paidAt");
        vm.assertEq(count, 3, "count");
        vm.assertEq(failedCount, 0, "failedCount");
        vm.assertEq(ledgerHash, bytes32(uint256(7)), "ledgerHash");
        vm.assertEq(tp, 60e18, "round totalPaid");
        vm.assertEq(token.balanceOf(alice), 10e18, "alice");
        vm.assertEq(token.balanceOf(bob), 20e18, "bob");
        vm.assertEq(token.balanceOf(carol), 30e18, "carol");
        vm.assertEq(token.balanceOf(address(payer)), 40e18, "remaining");
    }

    function test_payRoundIdempotent() public {
        _fund(100e18);
        _pay(1, _arr1(alice), _amt1(1e18));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.RoundAlreadyPaid.selector, 1));
        payer.payRound(1, address(token), _arr1(alice), _amt1(1e18), bytes32(0), 0, 0);
        // even with a different token / recipients the id is spent
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.RoundAlreadyPaid.selector, 1));
        payer.payRound(1, address(0x1234), _arr1(bob), _amt1(2e18), bytes32(0), 0, 0);
        vm.assertEq(token.balanceOf(alice), 1e18, "paid once");
        // a round id of zero works like any other
        _pay(0, _arr1(bob), _amt1(1e18));
        vm.assertTrue(payer.isPaid(0), "round 0 paid");
        // and the max id
        _pay(type(uint256).max, _arr1(bob), _amt1(1e18));
        vm.assertTrue(payer.isPaid(type(uint256).max), "max id paid");
    }

    function test_payRoundAccessAndShapeChecks() public {
        _fund(100e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payer.payRound(1, address(token), _arr1(alice), _amt1(1e18), bytes32(0), 0, 0);

        vm.prank(owner);
        vm.expectRevert(RoundPayout.LengthMismatch.selector);
        payer.payRound(1, address(token), _arr3(alice, bob, carol), _amt1(1e18), bytes32(0), 0, 0);

        vm.prank(owner);
        vm.expectRevert(RoundPayout.EmptyBatch.selector);
        payer.payRound(1, address(token), new address[](0), new uint256[](0), bytes32(0), 0, 0);

        address[] memory to = new address[](501);
        uint256[] memory amounts = new uint256[](501);
        for (uint256 i; i < 501; ++i) {
            to[i] = alice;
        }
        vm.prank(owner);
        vm.expectRevert(RoundPayout.BatchTooLarge.selector);
        payer.payRound(1, address(token), to, amounts, bytes32(0), 0, 0);
        vm.assertFalse(payer.isPaid(1), "nothing marked");
    }

    function test_payRoundExactly500Legs() public {
        _fund(500);
        address[] memory to = new address[](500);
        uint256[] memory amounts = new uint256[](500);
        for (uint256 i; i < 500; ++i) {
            to[i] = address(uint160(0x5000 + i));
            amounts[i] = 1;
        }
        uint256 paid = _pay(1, to, amounts);
        vm.assertEq(paid, 500, "all 500 paid");
        (,, uint256 count,,,) = _round(1);
        vm.assertEq(count, 500, "count 500");
        vm.assertEq(token.balanceOf(address(payer)), 0, "drained exactly");
    }

    function test_payRoundInsufficientBalanceUpFront() public {
        _fund(50e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.InsufficientBalance.selector, 60e18, 50e18));
        payer.payRound(1, address(token), _arr3(alice, bob, carol), _amt3(10e18, 20e18, 30e18), bytes32(0), 0, 0);
        vm.assertEq(token.balanceOf(alice), 0, "no partial payment");
        vm.assertFalse(payer.isPaid(1), "not paid");
        // exactly the balance passes
        uint256 paid = _pay(1, _arr3(alice, bob, carol), _amt3(10e18, 20e18, 20e18));
        vm.assertEq(paid, 50e18, "exact balance ok");
        vm.assertEq(token.balanceOf(address(payer)), 0, "empty");
        // one wei more than the (now zero) balance fails
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.InsufficientBalance.selector, 1, 0));
        payer.payRound(2, address(token), _arr1(alice), _amt1(1), bytes32(0), 0, 0);
    }

    function test_payRoundTokenWithoutCodeReverts() public {
        vm.prank(owner);
        vm.expectRevert();
        payer.payRound(1, address(0xDEAD), _arr1(alice), _amt1(1), bytes32(0), 0, 0);
    }

    function test_partialFailureAccounting() public {
        _fund(100e18);
        token.setMode(bob, 1); // reverts "blocked recipient"
        address[] memory to = _arr3(alice, bob, carol);
        uint256[] memory amounts = _amt3(10e18, 20e18, 30e18);

        vm.recordLogs();
        uint256 totalPaid = _pay(3, to, amounts);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        vm.assertEq(totalPaid, 40e18, "failed leg excluded");
        vm.assertTrue(payer.isPaid(3), "round marked paid despite the failure");
        vm.assertEq(payer.failed(3, bob), 20e18, "failed stored");
        vm.assertEq(payer.failed(3, alice), 0, "alice fine");
        (,, uint256 count, uint256 failedCount,, uint256 tp) = _round(3);
        vm.assertEq(count, 3, "count counts all legs");
        vm.assertEq(failedCount, 1, "one failed recipient");
        vm.assertEq(tp, 40e18, "round totalPaid");
        vm.assertEq(token.balanceOf(bob), 0, "bob unpaid");
        vm.assertEq(token.balanceOf(carol), 30e18, "batch continued after the failure");
        vm.assertEq(token.balanceOf(address(payer)), 60e18, "failed amount stays in the contract");

        // PayFailed carries the revert reason
        bool sawFail;
        uint256 paidEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(payer)) continue;
            if (logs[i].topics[0] == PAY_FAILED_SIG) {
                sawFail = true;
                vm.assertEq(address(uint160(uint256(logs[i].topics[2]))), bob, "failed recipient");
                (uint256 amt, bytes memory reason) = abi.decode(logs[i].data, (uint256, bytes));
                vm.assertEq(amt, 20e18, "failed amount");
                vm.assertEq(reason, abi.encodeWithSignature("Error(string)", "blocked recipient"), "reason");
            } else if (logs[i].topics[0] == PAID_SIG) {
                paidEvents += 1;
            }
        }
        vm.assertTrue(sawFail, "PayFailed emitted");
        vm.assertEq(paidEvents, 2, "two Paid events");
    }

    function test_everyFailureFlavourIsCaught() public {
        _fund(100e18);
        address r1 = address(0x2001); // revert with reason
        address r2 = address(0x2002); // returns false
        address r3 = address(0x2003); // burns all gas
        address r4 = address(0x2004); // returns nothing: success
        address r5 = address(0x2005); // returns garbage: failure
        address r6 = address(0x2006); // revert with no data
        token.setMode(r1, 1);
        token.setMode(r2, 2);
        token.setMode(r3, 3);
        token.setMode(r4, 4);
        token.setMode(r5, 5);
        token.setMode(r6, 6);
        address[] memory to = new address[](8);
        uint256[] memory amounts = new uint256[](8);
        to[0] = r1;
        to[1] = r2;
        to[2] = r3;
        to[3] = r4;
        to[4] = r5;
        to[5] = r6;
        to[6] = address(0); // zero recipient
        to[7] = alice;
        for (uint256 i; i < 8; ++i) {
            amounts[i] = 1e18;
        }
        uint256 paid = _pay(9, to, amounts);
        vm.assertEq(paid, 2e18, "only the no-return token and alice succeeded");
        vm.assertEq(payer.failed(9, r1), 1e18, "revert w/ reason stored");
        vm.assertEq(payer.failed(9, r2), 1e18, "returned false stored");
        vm.assertEq(payer.failed(9, r3), 1e18, "out of gas stored");
        vm.assertEq(payer.failed(9, r4), 0, "no-return success not stored");
        vm.assertEq(payer.failed(9, r5), 1e18, "garbage return stored");
        vm.assertEq(payer.failed(9, r6), 1e18, "silent revert stored");
        vm.assertEq(payer.failed(9, address(0)), 1e18, "zero recipient stored");
        (,,, uint256 failedCount,,) = _round(9);
        vm.assertEq(failedCount, 6, "six failed recipients");
        vm.assertEq(token.balanceOf(r4), 1e18, "r4 paid");
        vm.assertEq(token.balanceOf(r3), 0, "r3 not paid");
    }

    function test_allTransfersFailedRevertsAndLeavesNothing() public {
        _fund(100e18);
        token.setMode(alice, 1);
        token.setMode(bob, 2);
        vm.prank(owner);
        vm.expectRevert(RoundPayout.AllTransfersFailed.selector);
        payer.payRound(4, address(token), _arr3(alice, bob, address(0)), _amt3(1e18, 1e18, 1e18), bytes32(0), 0, 0);
        vm.assertFalse(payer.isPaid(4), "not marked paid");
        vm.assertEq(payer.failed(4, alice), 0, "nothing stored");
        (,,, uint256 failedCount,,) = _round(4);
        vm.assertEq(failedCount, 0, "failedCount rolled back");
        vm.assertEq(token.balanceOf(address(payer)), 100e18, "balance intact");
        // the same round id can be paid once the recipients are fixed
        token.setMode(alice, 0);
        token.setMode(bob, 0);
        _pay(4, _arr3(alice, bob, carol), _amt3(1e18, 1e18, 1e18));
        vm.assertTrue(payer.isPaid(4), "paid after fix");
    }

    function test_duplicateFailingRecipientAccumulates() public {
        _fund(100e18);
        token.setMode(bob, 1);
        address[] memory to = new address[](4);
        uint256[] memory amounts = new uint256[](4);
        to[0] = bob;
        to[1] = alice;
        to[2] = bob;
        to[3] = alice;
        amounts[0] = 1e18;
        amounts[1] = 2e18;
        amounts[2] = 3e18;
        amounts[3] = 4e18;
        uint256 paid = _pay(5, to, amounts);
        vm.assertEq(paid, 6e18, "alice twice");
        vm.assertEq(payer.failed(5, bob), 4e18, "bob's legs accumulate");
        (,, uint256 count, uint256 failedCount,,) = _round(5);
        vm.assertEq(count, 4, "four legs");
        vm.assertEq(failedCount, 1, "one distinct failed recipient");
        // retry pays the accumulated amount once and clears
        token.setMode(bob, 0);
        vm.prank(owner);
        payer.retryFailed(5, _arr1(bob));
        vm.assertEq(token.balanceOf(bob), 4e18, "bob paid in full");
        vm.assertEq(payer.failed(5, bob), 0, "cleared");
        (,,, failedCount,,) = _round(5);
        vm.assertEq(failedCount, 0, "failedCount back to zero");
    }

    function test_zeroAmountLegs() public {
        _fund(1e18);
        // a zero leg to a healthy recipient is a successful Paid(0)
        uint256 paid = _pay(6, _arr3(alice, bob, carol), _amt3(0, 0, 1e18));
        vm.assertEq(paid, 1e18, "zero legs add nothing");
        vm.assertEq(payer.failed(6, alice), 0, "no failure");
        // a zero leg that fails leaves no outstanding entry and no failedCount
        token.setMode(bob, 1);
        _pay(7, _arr3(alice, bob, carol), _amt3(0, 0, 0));
        vm.assertEq(payer.failed(7, bob), 0, "zero failed amount not stored");
        (,,, uint256 failedCount,,) = _round(7);
        vm.assertEq(failedCount, 0, "no failed recipient for a zero leg");
        vm.assertTrue(payer.isPaid(7), "round paid (not all legs failed)");
    }

    // --------------------------------------- retryFailed ---------------------------------------- //

    function test_retryFailedPathsAndAccess() public {
        _fund(100e18);
        token.setMode(bob, 1);
        token.setMode(carol, 2);
        _pay(1, _arr3(alice, bob, carol), _amt3(10e18, 20e18, 30e18));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payer.retryFailed(1, _arr1(bob));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.RoundNotPaid.selector, 2));
        payer.retryFailed(2, _arr1(bob));

        // a recipient with nothing stored is skipped: no revert, no payment, no event, no state change
        vm.prank(owner);
        vm.recordLogs();
        payer.retryFailed(1, _arr1(alice));
        vm.assertEq(vm.getRecordedLogs().length, 0, "skipped entry emits nothing");
        vm.assertEq(token.balanceOf(alice), 10e18, "alice not paid twice");
        (,,, uint256 fc0,, uint256 tp0) = _round(1);
        vm.assertEq(fc0, 2, "failedCount untouched by a skipped entry");
        vm.assertEq(tp0, 10e18, "totalPaid untouched by a skipped entry");

        // bob still fails: stays stored, PayFailed again; carol now fixed: paid and cleared
        token.setMode(carol, 0);
        address[] memory to = new address[](2);
        to[0] = bob;
        to[1] = carol;
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.PayFailed(1, bob, 20e18, abi.encodeWithSignature("Error(string)", "blocked recipient"));
        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.Paid(1, carol, 30e18);
        payer.retryFailed(1, to);
        vm.assertEq(payer.failed(1, bob), 20e18, "bob still outstanding");
        vm.assertEq(payer.failed(1, carol), 0, "carol cleared");
        vm.assertEq(token.balanceOf(carol), 30e18, "carol paid");
        (,,, uint256 failedCount,, uint256 tp) = _round(1);
        vm.assertEq(failedCount, 1, "one left");
        vm.assertEq(tp, 40e18, "totalPaid grows with the retry");

        // the same recipient twice in one call: the first entry pays, the second has nothing stored
        // and is skipped, so a duplicate can never pay twice
        token.setMode(bob, 0);
        to[0] = bob;
        to[1] = bob;
        vm.prank(owner);
        vm.recordLogs();
        payer.retryFailed(1, to);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paidEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(payer) && logs[i].topics[0] == keccak256("Paid(uint256,address,uint256)")) {
                paidEvents += 1;
            }
        }
        vm.assertEq(paidEvents, 1, "duplicate entry pays exactly once");
        vm.assertEq(token.balanceOf(bob), 20e18, "bob paid once");
        vm.assertEq(payer.failed(1, bob), 0, "bob cleared");
        (,,, failedCount,, tp) = _round(1);
        vm.assertEq(failedCount, 0, "none left");
        vm.assertEq(tp, 60e18, "all paid eventually");
        // nothing left to retry: a no-op, never a revert and never a second payment
        vm.prank(owner);
        payer.retryFailed(1, _arr1(bob));
        vm.assertEq(token.balanceOf(bob), 20e18, "no double pay");
        (,,, failedCount,, tp) = _round(1);
        vm.assertEq(tp, 60e18, "totalPaid stable");
    }

    function test_retryFailedWithInsufficientBalanceStaysStored() public {
        _fund(30e18);
        token.setMode(bob, 1);
        _pay(1, _arr3(alice, bob, carol), _amt3(10e18, 10e18, 10e18));
        // the owner sweeps the leftover; the retry cannot be paid and must not corrupt state
        vm.prank(owner);
        payer.sweep(address(token), owner, 10e18);
        token.setMode(bob, 0);
        vm.prank(owner);
        payer.retryFailed(1, _arr1(bob));
        vm.assertEq(payer.failed(1, bob), 10e18, "still outstanding");
        vm.assertEq(token.balanceOf(bob), 0, "not paid");
        (,,, uint256 failedCount,, uint256 tp) = _round(1);
        vm.assertEq(failedCount, 1, "failedCount unchanged");
        vm.assertEq(tp, 20e18, "totalPaid unchanged");
    }

    // -------------------------------------- writeOffFailed -------------------------------------- //

    function test_writeOffFailed() public {
        _fund(100e18);
        token.setMode(bob, 1);
        _pay(1, _arr3(alice, bob, carol), _amt3(10e18, 20e18, 30e18));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payer.writeOffFailed(1, bob);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.NothingFailed.selector, 1, alice));
        payer.writeOffFailed(1, alice);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.NothingFailed.selector, 99, bob));
        payer.writeOffFailed(99, bob);

        uint256 balBefore = token.balanceOf(address(payer));
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(payer));
        emit RoundPayout.WrittenOff(1, bob, 20e18);
        payer.writeOffFailed(1, bob);
        vm.assertEq(payer.failed(1, bob), 0, "cleared");
        vm.assertEq(token.balanceOf(address(payer)), balBefore, "no tokens moved");
        (,,, uint256 failedCount,, uint256 tp) = _round(1);
        vm.assertEq(failedCount, 0, "failedCount decremented");
        vm.assertEq(tp, 40e18, "totalPaid unchanged by a write-off");
        // can't write off twice; a retry of a written-off leg is skipped and pays nothing
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.NothingFailed.selector, 1, bob));
        payer.writeOffFailed(1, bob);
        token.setMode(bob, 0);
        vm.prank(owner);
        payer.retryFailed(1, _arr1(bob));
        vm.assertEq(token.balanceOf(bob), 0, "written-off leg is never paid by a retry");
        vm.assertEq(token.balanceOf(address(payer)), balBefore, "no tokens moved");
        (,,, failedCount,, tp) = _round(1);
        vm.assertEq(failedCount, 0, "failedCount stays zero");
        vm.assertEq(tp, 40e18, "totalPaid unchanged");
    }

    // ---------------------------------------- reentrancy ---------------------------------------- //

    /// @dev The re-entering token owns its own payer, so the reentrant call passes onlyOwner and
    ///      whenNotPaused and it is the guard that must stop it. The outer call is a payRound leg
    ///      (which tolerates a failing transfer), so the token's record of the inner error survives.
    function _reentrantSetup() internal returns (ReentrantToken rt, RoundPayout p2) {
        rt = new ReentrantToken();
        p2 = new RoundPayout(address(rt));
        rt.mint(address(p2), 100e18);
    }

    function _outerPayRound(ReentrantToken rt, RoundPayout p2, uint256 roundId) internal returns (uint256 paid) {
        bytes memory ret = rt.exec(
            address(p2),
            abi.encodeCall(
                p2.payRound, (roundId, address(rt), _arr3(alice, bob, carol), _amt3(1e18, 1e18, 1e18), bytes32(0), 0, 0)
            )
        );
        paid = abi.decode(ret, (uint256));
    }

    function _assertGuardTripped(ReentrantToken rt) internal view {
        vm.assertEq(rt.reentries(), 1, "re-entry attempted once");
        vm.assertFalse(rt.reentrySucceeded(), "reentrant call rejected");
        vm.assertEq(
            bytes32(bytes4(rt.lastReentryError())),
            bytes32(RoundPayout.ReentrancyGuardReentrantCall.selector),
            "rejected by the reentrancy guard"
        );
    }

    function test_reentrancyFromTokenIntoPayRoundIsBlocked() public {
        (ReentrantToken rt, RoundPayout p2) = _reentrantSetup();
        rt.arm(p2, abi.encodeCall(p2.payRound, (2, address(rt), _arr1(bob), _amt1(1e18), bytes32(0), 0, 0)));
        uint256 paid = _outerPayRound(rt, p2, 1);
        _assertGuardTripped(rt);
        vm.assertFalse(p2.isPaid(2), "nested round never paid");
        vm.assertEq(paid, 2e18, "the re-entering leg failed, the rest continued");
        vm.assertEq(p2.failed(1, alice), 1e18, "first leg stored as failed");
        vm.assertEq(rt.balanceOf(address(p2)), 98e18, "exactly two legs left the contract");
    }

    function test_reentrancyFromTokenIntoSweepIsBlocked() public {
        (ReentrantToken rt, RoundPayout p2) = _reentrantSetup();
        rt.arm(p2, abi.encodeCall(p2.sweep, (address(rt), address(rt), 50e18)));
        uint256 paid = _outerPayRound(rt, p2, 1);
        _assertGuardTripped(rt);
        vm.assertEq(paid, 2e18, "outer round continued");
        vm.assertEq(rt.balanceOf(address(rt)), 0, "nested sweep moved nothing");
    }

    function test_reentrancyFromTokenIntoRetryFailedIsBlocked() public {
        (ReentrantToken rt, RoundPayout p2) = _reentrantSetup();
        // a plain first round with the token idle, leaving nothing failed; then arm and re-enter retry
        rt.arm(p2, abi.encodeCall(p2.retryFailed, (1, _arr1(alice))));
        uint256 paid = _outerPayRound(rt, p2, 1);
        _assertGuardTripped(rt);
        vm.assertEq(paid, 2e18, "outer round continued");
    }

    function test_reentrancyGuardReleasesAfterTheCall() public {
        (ReentrantToken rt, RoundPayout p2) = _reentrantSetup();
        rt.arm(p2, abi.encodeCall(p2.pause, ()));
        _outerPayRound(rt, p2, 1);
        // pause() has no guard, so the nested call went through: the lock must still be released
        vm.assertTrue(rt.reentrySucceeded(), "unguarded owner call allowed");
        vm.assertTrue(p2.paused(), "paused from inside");
        rt.exec(address(p2), abi.encodeCall(p2.unpause, ()));
        rt.arm(p2, "");
        uint256 paid = _outerPayRound(rt, p2, 2);
        vm.assertEq(paid, 3e18, "guard released: next round pays in full");
    }

    // ------------------------------------------ fuzz -------------------------------------------- //

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_payRoundConservesTokens(uint256 n, uint256 seed, uint256 funding) public {
        n = _bound(n, 1, 60);
        funding = _bound(funding, 0, 1_000_000e18);
        _fund(funding);
        address[] memory to = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 sum;
        uint256 expectedFailed;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            to[i] = address(uint160(0x7000 + (r % 20)));
            amounts[i] = r % 1000e18;
            sum += amounts[i];
        }
        // every third recipient fails
        for (uint256 i; i < 20; ++i) {
            if (i % 3 == 0) token.setMode(address(uint160(0x7000 + i)), 1);
        }
        for (uint256 i; i < n; ++i) {
            if (token.mode(to[i]) == 1) expectedFailed += amounts[i];
        }
        if (sum > funding) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.InsufficientBalance.selector, sum, funding));
            payer.payRound(1, address(token), to, amounts, bytes32(0), 0, 0);
            return;
        }
        if (expectedFailed == sum && _allFail(to)) {
            vm.prank(owner);
            vm.expectRevert(RoundPayout.AllTransfersFailed.selector);
            payer.payRound(1, address(token), to, amounts, bytes32(0), 0, 0);
            return;
        }
        uint256 paid = _pay(1, to, amounts);
        vm.assertEq(paid, sum - expectedFailed, "totalPaid == sum - failed");
        vm.assertEq(token.balanceOf(address(payer)), funding - paid, "balance == funded - paid");
        vm.assertLe(paid, funding, "never pays more than funded");
        uint256 outstanding;
        for (uint256 i; i < 20; ++i) {
            outstanding += payer.failed(1, address(uint160(0x7000 + i)));
        }
        vm.assertEq(outstanding, expectedFailed, "failed entries sum to the failed legs");
    }

    function _allFail(address[] memory to) internal view returns (bool) {
        for (uint256 i; i < to.length; ++i) {
            if (token.mode(to[i]) != 1) return false;
        }
        return true;
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_roundIdNeverReopens(uint256 roundId, uint256 amount) public {
        amount = _bound(amount, 1, 1000e18);
        _fund(2000e18);
        _pay(roundId, _arr1(alice), _amt1(amount));
        vm.assertTrue(payer.isPaid(roundId), "paid");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.RoundAlreadyPaid.selector, roundId));
        payer.payRound(roundId, address(token), _arr1(alice), _amt1(amount), bytes32(0), 0, 0);
        vm.assertEq(token.balanceOf(alice), amount, "paid exactly once");
    }
}

// ============================================================================================= //
//                                           invariants                                          //
// ============================================================================================= //

contract PayoutHandler is TestBase {
    RoundPayout public payer;
    FlakyToken public token;
    address public owner;

    uint256 public ghostFunded;
    uint256 public ghostPaid; // sum of Paid event amounts
    uint256 public ghostSwept;
    uint256 public ghostOutstanding; // sum of stored failed amounts
    uint256 public ghostWrittenOff;
    uint256 public ghostReopened;
    uint256 public ghostRounds;
    uint256 public ghostPausedPayAttempts;
    uint256 public ghostPausedPaySucceeded;
    mapping(uint256 => bool) public ghostPaid_;
    uint256[] public paidRounds;
    uint256 public nextRound;

    bytes32 internal constant PAID_SIG = keccak256("Paid(uint256,address,uint256)");

    address[] internal recipients;

    constructor(RoundPayout p, FlakyToken t, address o) {
        payer = p;
        token = t;
        owner = o;
        for (uint256 i; i < 8; ++i) {
            recipients.push(address(uint160(0x9000 + i)));
        }
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function recipientAt(uint256 i) external view returns (address) {
        return recipients[i];
    }

    function paidRoundCount() external view returns (uint256) {
        return paidRounds.length;
    }

    function fund(uint256 amount) external {
        amount = _bound(amount, 0, 100e18);
        token.mint(address(this), amount);
        token.approve(address(payer), amount);
        payer.fund(address(token), amount);
        ghostFunded += amount;
    }

    function toggleFailing(uint256 idx, bool failing) external {
        idx = _bound(idx, 0, recipients.length - 1);
        token.setMode(recipients[idx], failing ? 1 : 0);
    }

    function payRound(uint256 n, uint256 seed, bool reuseId) external {
        n = _bound(n, 1, 6);
        address[] memory to = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            to[i] = recipients[r % recipients.length];
            amounts[i] = r % 10e18;
            sum += amounts[i];
        }
        uint256 roundId = (reuseId && paidRounds.length != 0) ? paidRounds[seed % paidRounds.length] : nextRound;
        bool wasPaid = payer.isPaid(roundId);
        if (payer.paused()) ghostPausedPayAttempts += 1;
        vm.recordLogs();
        vm.prank(owner);
        try payer.payRound(roundId, address(token), to, amounts, bytes32(seed), 0, 0) returns (uint256) {
            if (payer.paused()) ghostPausedPaySucceeded += 1;
            if (wasPaid) ghostReopened += 1;
            _sumPaid();
            ghostPaid_[roundId] = true;
            paidRounds.push(roundId);
            ghostOutstanding = _recountOutstanding();
            ghostRounds += 1;
            nextRound += 1;
        } catch {
            // InsufficientBalance / AllTransfersFailed / paused / already paid: no state change
        }
    }

    function retryFailed(uint256 roundSeed, uint256 idx) external {
        if (paidRounds.length == 0) return;
        uint256 roundId = paidRounds[roundSeed % paidRounds.length];
        idx = _bound(idx, 0, recipients.length - 1);
        address[] memory to = new address[](1);
        to[0] = recipients[idx];
        vm.recordLogs();
        vm.prank(owner);
        try payer.retryFailed(roundId, to) {
            _sumPaid();
            ghostOutstanding = _recountOutstanding();
        } catch {}
    }

    function writeOff(uint256 roundSeed, uint256 idx) external {
        if (paidRounds.length == 0) return;
        uint256 roundId = paidRounds[roundSeed % paidRounds.length];
        idx = _bound(idx, 0, recipients.length - 1);
        vm.prank(owner);
        try payer.writeOffFailed(roundId, recipients[idx]) {
            ghostOutstanding = _recountOutstanding();
        } catch {}
    }

    function sweep(uint256 amount) external {
        amount = _bound(amount, 0, token.balanceOf(address(payer)));
        vm.prank(owner);
        try payer.sweep(address(token), owner, amount) {
            ghostSwept += amount;
        } catch {}
    }

    function pause(bool on) external {
        vm.prank(owner);
        if (on) {
            try payer.pause() {} catch {}
        } else {
            try payer.unpause() {} catch {}
        }
    }

    function _sumPaid() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(payer) && logs[i].topics[0] == PAID_SIG) {
                ghostPaid += abi.decode(logs[i].data, (uint256));
            }
        }
    }

    function _recountOutstanding() internal view returns (uint256 total) {
        for (uint256 r; r < paidRounds.length; ++r) {
            for (uint256 i; i < recipients.length; ++i) {
                total += payer.failed(paidRounds[r], recipients[i]);
            }
        }
    }
}

contract RoundPayoutInvariantTest is PayoutFixture {
    PayoutHandler internal handler;

    function setUp() public {
        _setUpFixture();
        handler = new PayoutHandler(payer, token, owner);
    }

    function targetContracts() public view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(handler);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_balanceEqualsFundedMinusPaidMinusSwept() public view {
        vm.assertEq(
            token.balanceOf(address(payer)),
            handler.ghostFunded() - handler.ghostPaid() - handler.ghostSwept(),
            "balance == funded - paid - swept"
        );
        vm.assertLe(handler.ghostPaid(), handler.ghostFunded(), "sum(Paid) <= funded");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_roundsNeverReopenAndTotalsMatch() public view {
        vm.assertEq(handler.ghostReopened(), 0, "a paid round never pays again");
        vm.assertEq(handler.ghostPausedPaySucceeded(), 0, "pause blocks payRound");
        uint256 n = handler.paidRoundCount();
        uint256 sumTotals;
        for (uint256 i; i < n; ++i) {
            uint256 roundId = handler.paidRounds(i);
            vm.assertTrue(payer.isPaid(roundId), "stays paid");
            (address t, uint256 paidAt,, uint256 failedCount,, uint256 totalPaid) = payer.rounds(roundId);
            vm.assertEq(t, address(token), "round token");
            vm.assertTrue(paidAt != 0, "paidAt set");
            sumTotals += totalPaid;
            // failedCount == number of recipients with an outstanding entry
            uint256 distinct;
            for (uint256 j; j < handler.recipientCount(); ++j) {
                if (payer.failed(roundId, handler.recipientAt(j)) != 0) distinct += 1;
            }
            vm.assertEq(failedCount, distinct, "failedCount == distinct outstanding recipients");
        }
        vm.assertEq(sumTotals, handler.ghostPaid(), "sum of round totals == sum of Paid events");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_outstandingFailedIsBounded() public view {
        // what is still owed to failed recipients never exceeds what has been funded and not paid out
        vm.assertEq(handler.ghostOutstanding(), _outstanding(), "ghost outstanding matches storage");
        vm.assertLe(
            handler.ghostPaid() + handler.ghostSwept(), handler.ghostFunded(), "nothing left the contract unfunded"
        );
    }

    function _outstanding() internal view returns (uint256 total) {
        uint256 n = handler.paidRoundCount();
        for (uint256 i; i < n; ++i) {
            uint256 roundId = handler.paidRounds(i);
            for (uint256 j; j < handler.recipientCount(); ++j) {
                total += payer.failed(roundId, handler.recipientAt(j));
            }
        }
    }
}
