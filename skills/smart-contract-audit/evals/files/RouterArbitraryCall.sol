// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Aggregator-style swap router. Users approve this router for their input token once;
/// each swap pulls `amountIn`, approves the DEX `target`, and executes the supplied calldata.
/// The target is expected to send `tokenOut` straight to `receiver` and return the amount sent.
contract RouterArbitraryCall {
    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address target;
        bytes data;
    }

    event Swapped(
        address indexed user, address indexed receiver, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );

    function swap(SwapParams calldata p, address receiver) external payable returns (uint256) {
        return _swap(p, receiver);
    }

    function multiSwap(SwapParams[] calldata ps, address receiver) external payable returns (uint256[] memory outs) {
        outs = new uint256[](ps.length);
        for (uint256 i = 0; i < ps.length; i++) {
            outs[i] = _swap(ps[i], receiver);
        }
    }

    function _swap(SwapParams calldata p, address receiver) internal returns (uint256 amountOut) {
        bool ok;
        bytes memory ret;
        if (p.tokenIn == NATIVE) {
            require(msg.value >= p.amountIn, "insufficient value");
            (ok, ret) = p.target.call{value: p.amountIn}(p.data);
        } else {
            IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
            IERC20(p.tokenIn).approve(p.target, p.amountIn);
            (ok, ret) = p.target.call(p.data);
        }
        require(ok, "swap failed");

        amountOut = abi.decode(ret, (uint256));
        require(amountOut >= p.minAmountOut, "slippage");
        emit Swapped(msg.sender, receiver, p.tokenIn, p.tokenOut, p.amountIn, amountOut);
    }

    /// @notice Recover tokens or ETH left in the router after partial fills or refunds.
    function sweep(address token, address to) external {
        if (token == NATIVE) {
            (bool ok,) = to.call{value: address(this).balance}("");
            require(ok, "eth transfer failed");
        } else {
            IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
        }
    }

    receive() external payable {}
}
