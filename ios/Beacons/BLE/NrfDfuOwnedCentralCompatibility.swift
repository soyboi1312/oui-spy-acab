import CoreBluetooth
import NordicDFU

/// The NordicDFU 4.x call that lets ACAB retain ownership of the exact central manager used
/// for Legacy DFU. Keep this file deliberately tiny; all other flasher warnings remain visible.
///
/// Nordic's replacement `init(queue:)` creates a private central manager. When paired with that
/// initializer, `start(target:)` retrieves a private copy of the peripheral. That is unsafe for
/// this bootloader: if its Legacy START response is lost, `DFUServiceController.abort()` marks the
/// operation aborted but does not disconnect the wedged link. NrfDfuFlasher's watchdog must be
/// able to cancel that exact link through the central manager it owns. The project is pinned to
/// NordicDFU 4.x, where this initializer remains available; a future removal will fail compilation
/// instead of silently changing the connection-ownership invariant.
private protocol OwnedCentralDFUBridge {
    func initiator(
        centralManager: CBCentralManager,
        target: CBPeripheral
    ) -> DFUServiceInitiator
}

/// Swift suppresses deprecation diagnostics inside a declaration that is itself deprecated. The
/// nondeprecated protocol surface lets the app reach this intentional NordicDFU 4.x call
/// without suppressing any warning outside this compatibility witness.
private struct NordicDFU4OwnedCentralBridge: OwnedCentralDFUBridge {
    @available(*, deprecated, message: "Intentional NordicDFU 4.x owned-central compatibility")
    func initiator(
        centralManager: CBCentralManager,
        target: CBPeripheral
    ) -> DFUServiceInitiator {
        DFUServiceInitiator(centralManager: centralManager, target: target)
    }
}

enum NrfDfuOwnedCentralCompatibility {
    private static let bridge: any OwnedCentralDFUBridge = NordicDFU4OwnedCentralBridge()

    static func initiator(
        centralManager: CBCentralManager,
        target: CBPeripheral
    ) -> DFUServiceInitiator {
        bridge.initiator(centralManager: centralManager, target: target)
    }
}
