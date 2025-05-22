import "./vault-interface";
import "../math";
import "../core/messages.tact";
import "../core/liquidity-deposit";
import "../core/amm-pool";
import "../utils/utils";

message(0xf8a7ea5) ReturnJettonsViaJettonTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    destination: Address;
    responseDestination: Address?;
    customPayload: Cell?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(0x7362d09c) UnexpectedJettonNotification {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    forwardPayload: Slice as remaining;
}

contract TonVault(
    admin: Address,
) with VaultInterface {
    override fun handlePayout(msg: PayoutFromPool) {
        let sortedAddresses = sortAddresses(myAddress(), msg.otherVault);
        let poolInit = initOf AmmPool(sortedAddresses.lower, sortedAddresses.higher, 0, 0, 0, null);

        require(poolInit.hasSameBasechainAddress(sender()), "TonVault: Sender must be pool");
        // -> (fee) -> (ton vault) -> [(0.2) + amount 10 ton]
        message(MessageParameters {
            to: msg.receiver,
            value: msg.amount,
            mode: SendRemainingValue,
            bounce: false,
            body: msg.payloadToForward,
        });
    }

    receive(msg: SwapRequestTon) {
        // TODO: exact tests for this
        nativeReserve(msg.amount, ReserveExact | ReserveAddOriginalBalance);

        message(MessageParameters {
            to: msg.action.pool,
            value: 0,
            mode: SendBounceIfActionFail | SendRemainingBalance,
            bounce: false,
            body: SwapIn {
                swapOutReceiver: msg.action.receiver != null ? msg.action.receiver!! : sender(),
                amount: msg.amount,
                isExactOutType: msg.action.isExactOutType,
                limit: msg.action.limit,
                timeout: msg.action.timeout,
                payloadOnSuccess: msg.action.payloadOnSuccess,
                payloadOnFailure: msg.action.payloadOnFailure,
                nextStep: msg.action.nextStep,
            }.toCell(),
        });
    }

    // Someone possibly transferred us jettons by accident
    receive(msg: UnexpectedJettonNotification) {
        message(MessageParameters {
            mode: SendRemainingValue,
            value: 0,
            body: ReturnJettonsViaJettonTransfer {
                queryId: msg.queryId,
                amount: msg.amount,
                destination: msg.sender,
                responseDestination: msg.sender,
                customPayload: null,
                forwardTonAmount: 1,
                forwardPayload: sliceWithOneZeroBit(),
            }.toCell(),
            to: sender(),
            bounce: true,
        });
        commit();
        require(false, "TonVault: Jetton transfer must be performed to correct Jetton Vault");
    }

    receive(msg: AddLiquidityPartTon) {
        // TODO: exact tests for this
        nativeReserve(msg.amountIn, ReserveExact | ReserveAddOriginalBalance);

        message(MessageParameters {
            to: msg.liquidityDepositContract,
            value: 0,
            mode: SendBounceIfActionFail | SendRemainingBalance,
            bounce: false,
            body: PartHasBeenDeposited {
                additionalParams: msg.additionalParams,
                amount: msg.amountIn,
                depositor: sender(),
            }.toCell(),
        });
    }

    receive() {}
}
