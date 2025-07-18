// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LPToken
 * @notice ERC677 token representing liquidity provider shares in the StableSwap pool
 * @dev Only the pool contract (owner) can mint tokens
 */
contract LPToken is ERC20, Ownable {
    // Custom errors
    error NotAuthorized();
    
    // Event emitted when transferAndCall is called
    event TransferAndCall(address indexed from, address indexed to, uint256 value, bytes data);

    /**
     * @notice Constructor to create the LP token
     * @param name_ Name of the LP token
     * @param symbol_ Symbol of the LP token
     */
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        // Initially owned by the factory, will be transferred to the pool
    }

    /**
     * @notice Mints new LP tokens to a recipient
     * @dev Can only be called by the pool contract (owner)
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burns LP tokens from a holder
     * @dev Can only be called by the pool contract (owner)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }


    
    /**
     * @notice Transfer tokens and call the receiver's onTokenTransfer function
     * @param _to Address to receive the tokens
     * @param _value Amount of tokens to transfer
     * @param _data Additional data to send to the receiver
     * @return success Whether the operation was successful
     */
    function transferAndCall(address _to, uint256 _value, bytes calldata _data) external returns (bool success) {
        transfer(_to, _value);
        emit TransferAndCall(msg.sender, _to, _value, _data);
        
        if (isContract(_to)) {
            contractFallback(_to, _value, _data);
        }
        return true;
    }
    
    /**
     * @notice Call the contractReceiver's onTokenTransfer function
     * @param _to Address of the contract receiving the tokens
     * @param _value Amount of tokens transferred
     * @param _data Additional data to send to the receiver
     */
    function contractFallback(address _to, uint256 _value, bytes calldata _data) private {
        // Interface for ERC677 token receivers
        ERC677Receiver receiver = ERC677Receiver(_to);
        receiver.onTokenTransfer(msg.sender, _value, _data);
    }
    
    /**
     * @notice Check if an address is a contract
     * @param _addr Address to check
     * @return True if the address is a contract
     */
    function isContract(address _addr) private view returns (bool) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(_addr)
        }
        return codeSize > 0;
    }
}

/**
 * @title ERC677Receiver
 * @dev Interface for contracts that will receive ERC677 tokens
 */
interface ERC677Receiver {
    function onTokenTransfer(address _sender, uint256 _value, bytes calldata _data) external;
}