package id.ac.usu.resqmesh

import org.junit.Assert.assertEquals
import org.junit.Test

class NativeBluetoothEnableRequestTest {
    @Test fun unavailableAdapterNeverRequestsConsent() {
        assertEquals("unavailable", NativeBluetoothEnableRequest.decision(false, true, false))
    }
    @Test fun permissionIsRequiredBeforeReadingOrRequestingAdapter() {
        assertEquals("permission_required", NativeBluetoothEnableRequest.decision(true, false, false))
    }
    @Test fun enabledAdapterDoesNotOpenAnotherDialog() {
        assertEquals("already_enabled", NativeBluetoothEnableRequest.decision(true, true, true))
    }
    @Test fun disabledAdapterRequiresConsentRatherThanClaimingEnabled() {
        assertEquals("request_consent", NativeBluetoothEnableRequest.decision(true, true, false))
    }
}
