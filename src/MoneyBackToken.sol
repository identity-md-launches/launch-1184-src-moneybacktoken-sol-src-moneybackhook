// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMD Money Back token ($MONEYBACK)
/// @notice Plain fixed-supply ERC20. The whole supply (1_000_000_000e18) is minted once to the
///         deployer (the IMD launch factory) in the constructor. There is no owner, no mint, no burn,
///         no transfer fee, no pause and no upgrade path. The contract is a self-contained ERC20
///         (OpenZeppelin v5 semantics and error names) because the launch build vendors no libraries.
contract MoneyBackToken {
    // ----------------------------------------------------------------------------------------- //
    //                                        ERC20 metadata                                      //
    // ----------------------------------------------------------------------------------------- //

    string public constant name = "IMD Money Back";
    string public constant symbol = "MONEYBACK";
    uint8 public constant decimals = 18;

    /// @notice Fixed total supply: 1 billion tokens, 18 decimals. Never changes after construction.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    // ----------------------------------------------------------------------------------------- //
    //                                             state                                          //
    // ----------------------------------------------------------------------------------------- //

    uint256 public immutable totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    // ----------------------------------------------------------------------------------------- //
    //                                       events and errors                                    //
    // ----------------------------------------------------------------------------------------- //

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);

    // ----------------------------------------------------------------------------------------- //
    //                                          constructor                                       //
    // ----------------------------------------------------------------------------------------- //

    /// @notice Mints TOTAL_SUPPLY to msg.sender exactly once. No constructor arguments.
    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ----------------------------------------------------------------------------------------- //
    //                                             ERC20                                          //
    // ----------------------------------------------------------------------------------------- //

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    // ----------------------------------------------------------------------------------------- //
    //                                           internals                                        //
    // ----------------------------------------------------------------------------------------- //

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            balanceOf[from] = fromBalance - value;
            // Sum of all balances is always TOTAL_SUPPLY, so this cannot overflow.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) internal {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 current = allowance[owner][spender];
        if (current != type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance(spender, current, value);
            unchecked {
                allowance[owner][spender] = current - value;
            }
        }
    }
}
