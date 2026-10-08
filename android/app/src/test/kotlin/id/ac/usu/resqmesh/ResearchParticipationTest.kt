package id.ac.usu.resqmesh

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ResearchParticipationTest {
    @Test fun scannerOffToOnIsAnActivationEvenWhenTxWasOn() {
        assertTrue(ResearchParticipation.reactivates(true, true, false, true))
    }
    @Test fun wholeNodeOffToOnIsAnActivation() {
        assertTrue(ResearchParticipation.reactivates(true, false, false, false))
        assertTrue(ResearchParticipation.reactivates(true, false, true, false))
    }
    @Test fun repeatedOnIsNotAnActivation() {
        assertFalse(ResearchParticipation.reactivates(true, true, true, true))
        assertFalse(ResearchParticipation.reactivates(true, false, true, true))
        assertFalse(ResearchParticipation.reactivates(true, true, true, false))
    }
    @Test fun disablingDoesNotOpenDiscovery() {
        assertFalse(ResearchParticipation.reactivates(false, true, true, true))
        assertFalse(ResearchParticipation.reactivates(false, false, false, false))
    }
}
