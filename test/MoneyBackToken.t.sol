// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MoneyBackToken} from "src/MoneyBackToken.sol";

// ============================================================================================= //
//  Self-contained harness (the project vendors no libraries, so no forge-std).                   //
// ============================================================================================= //

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function label(address, string calldata) external;
    function assume(bool) external pure;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool) external;
    function expectEmit(bool, bool, bool, bool, address) external;
    function assertEq(uint256, uint256, string calldata) external pure;
    function assertEq(address, address, string calldata) external pure;
    function assertEq(string calldata, string calldata, string calldata) external pure;
    function assertEq(bool, bool, string calldata) external pure;
    function assertTrue(bool, string calldata) external pure;
    function assertFalse(bool, string calldata) external pure;
    function assertLe(uint256, uint256, string calldata) external pure;
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

/// @dev Deploys the token from a separate account to show the supply goes to msg.sender (the factory).
contract Factory {
    MoneyBackToken public token;

    function deploy() external returns (MoneyBackToken t) {
        t = new MoneyBackToken();
        token = t;
    }
}

// ============================================================================================= //
//                                          unit tests                                           //
// ============================================================================================= //

contract MoneyBackTokenTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    MoneyBackToken internal token;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        vm.expectEmit(true, true, false, true);
        emit MoneyBackToken.Transfer(address(0), address(this), SUPPLY);
        token = new MoneyBackToken();
    }

    function test_metadataAndFixedSupply() public view {
        vm.assertEq(token.name(), "IMD Money Back", "name");
        vm.assertEq(token.symbol(), "MONEYBACK", "symbol");
        vm.assertEq(uint256(token.decimals()), 18, "decimals");
        vm.assertEq(token.totalSupply(), SUPPLY, "totalSupply");
        vm.assertEq(token.TOTAL_SUPPLY(), SUPPLY, "TOTAL_SUPPLY");
        vm.assertEq(token.balanceOf(address(this)), SUPPLY, "whole supply to deployer");
    }

    function test_supplyGoesToTheDeployerOnly() public {
        Factory f = new Factory();
        MoneyBackToken t = f.deploy();
        vm.assertEq(t.balanceOf(address(f)), SUPPLY, "factory holds everything");
        vm.assertEq(t.balanceOf(address(this)), 0, "caller of the factory gets nothing");
        vm.assertEq(t.totalSupply(), SUPPLY, "supply");
    }

    function test_noMintBurnOwnerOrPauseSurface() public {
        bytes4[9] memory sels = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("burn(address,uint256)")),
            bytes4(keccak256("burnFrom(address,uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("setFee(uint256)")),
            bytes4(keccak256("upgradeTo(address)"))
        ];
        for (uint256 i; i < sels.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(sels[i], address(this), uint256(1)));
            vm.assertFalse(ok, "selector must not exist");
        }
        vm.assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
        (bool sent,) = address(token).call{value: 1}("");
        vm.assertFalse(sent, "no ETH accepted");
    }

    // ---------------------------------------- transfer ------------------------------------------ //

    function test_transferMovesBalanceWithoutFee() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit MoneyBackToken.Transfer(address(this), alice, 123e18);
        vm.assertTrue(token.transfer(alice, 123e18), "returns true");
        vm.assertEq(token.balanceOf(alice), 123e18, "alice gets exactly the amount");
        vm.assertEq(token.balanceOf(address(this)), SUPPLY - 123e18, "sender debited exactly");
        vm.assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
    }

    function test_transferEdgeAmounts() public {
        vm.assertTrue(token.transfer(alice, 0), "zero transfer ok");
        vm.assertEq(token.balanceOf(alice), 0, "zero");
        vm.assertTrue(token.transfer(alice, SUPPLY), "whole balance ok");
        vm.assertEq(token.balanceOf(alice), SUPPLY, "alice has all");
        vm.assertEq(token.balanceOf(address(this)), 0, "sender empty");
        // self transfer keeps the balance
        vm.prank(alice);
        token.transfer(alice, SUPPLY);
        vm.assertEq(token.balanceOf(alice), SUPPLY, "self transfer is a no-op");
    }

    function test_transferInsufficientBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.assertEq(token.totalSupply(), SUPPLY, "no burn path");
    }

    // ------------------------------------ approve / transferFrom ------------------------------- //

    function test_approveAndTransferFrom() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit MoneyBackToken.Approval(address(this), alice, 50e18);
        vm.assertTrue(token.approve(alice, 50e18), "approve returns true");
        vm.assertEq(token.allowance(address(this), alice), 50e18, "allowance set");

        vm.prank(alice);
        vm.assertTrue(token.transferFrom(address(this), bob, 20e18), "transferFrom returns true");
        vm.assertEq(token.balanceOf(bob), 20e18, "bob paid");
        vm.assertEq(token.allowance(address(this), alice), 30e18, "allowance decremented");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientAllowance.selector, alice, 30e18, 31e18));
        token.transferFrom(address(this), bob, 31e18);

        // approvals overwrite, they do not add
        token.approve(alice, 5e18);
        vm.assertEq(token.allowance(address(this), alice), 5e18, "overwritten");
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1e18);
        vm.assertEq(token.allowance(address(this), alice), type(uint256).max, "still infinite");
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(this), bob, 1);
        // allowance is checked before balance: an approved spender of an empty account fails on balance
        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientBalance.selector, alice, 0, 10));
        token.transferFrom(alice, bob, 10);
        // and the allowance was consumed by the failed attempt? No: the whole call reverted.
        vm.assertEq(token.allowance(alice, bob), 10, "allowance untouched by a revert");
    }

    function test_transferFromToZeroAndApproveZeroSpenderRevert() public {
        token.approve(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ------------------------------------------ fuzz -------------------------------------------- //

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transferPreservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = _bound(amount, 0, SUPPLY);
        token.transfer(to, amount);
        vm.assertEq(token.balanceOf(to), amount, "recipient");
        vm.assertEq(token.balanceOf(address(this)) + token.balanceOf(to), SUPPLY, "conserved");
        vm.assertEq(token.totalSupply(), SUPPLY, "supply fixed");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transferAboveBalanceAlwaysReverts(uint256 amount) public {
        amount = _bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(alice, amount);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transferFromRespectsAllowance(uint256 allowance_, uint256 amount) public {
        allowance_ = _bound(allowance_, 0, SUPPLY);
        amount = _bound(amount, 0, SUPPLY);
        token.approve(alice, allowance_);
        vm.prank(alice);
        if (amount > allowance_) {
            vm.expectRevert(
                abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientAllowance.selector, alice, allowance_, amount)
            );
            token.transferFrom(address(this), bob, amount);
        } else {
            token.transferFrom(address(this), bob, amount);
            vm.assertEq(token.allowance(address(this), alice), allowance_ - amount, "allowance spent exactly");
            vm.assertEq(token.balanceOf(bob), amount, "bob");
        }
    }
}

// ============================================================================================= //
//                                           invariants                                          //
// ============================================================================================= //

contract TokenHandler is TestBase {
    MoneyBackToken public token;
    address[] public actors;
    uint256 public ghostTransfers;
    uint256 public ghostReverts;

    constructor(MoneyBackToken t, address initialHolder) {
        token = t;
        actors.push(initialHolder);
        for (uint256 i = 1; i <= 6; ++i) {
            actors.push(address(uint160(0x4000 + i)));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = _bound(amount, 0, token.balanceOf(from) + 1); // sometimes one over the balance
        vm.prank(from);
        try token.transfer(to, amount) {
            ghostTransfers += 1;
        } catch {
            ghostReverts += 1;
        }
    }

    function approveAndTransferFrom(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 amount,
        bool infinite
    ) external {
        address owner_ = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = _bound(amount, 0, token.balanceOf(owner_) + 1);
        vm.prank(owner_);
        token.approve(spender, infinite ? type(uint256).max : amount);
        vm.prank(spender);
        try token.transferFrom(owner_, to, amount) {
            ghostTransfers += 1;
        } catch {
            ghostReverts += 1;
        }
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        vm.prank(from);
        try token.transfer(address(0), amount) {
            ghostTransfers += 1;
        } catch {
            ghostReverts += 1;
        }
    }
}

contract MoneyBackTokenInvariantTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    MoneyBackToken internal token;
    TokenHandler internal handler;

    function setUp() public {
        token = new MoneyBackToken();
        handler = new TokenHandler(token, address(this));
        // the handler moves tokens on behalf of actors; seed it as an actor too
        token.transfer(address(handler), SUPPLY / 2);
        handler = handler; // silence
    }

    function targetContracts() public view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(handler);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_supplyIsFixedAndConserved() public view {
        vm.assertEq(token.totalSupply(), SUPPLY, "supply never changes");
        uint256 sum = token.balanceOf(address(handler));
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        vm.assertEq(sum, SUPPLY, "sum of balances == supply");
        vm.assertEq(token.balanceOf(address(0)), 0, "nothing ever burnt to zero");
    }
}
