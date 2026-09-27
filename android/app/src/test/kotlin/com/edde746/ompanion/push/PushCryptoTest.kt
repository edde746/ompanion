package com.edde746.ompanion.push

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Base64

// The test vector of docs/contracts/push.md, which the companion's sender and the iOS extension decrypt too.
class PushCryptoTest {
    @Test
    fun decryptsTheContractTestVector() {
        val base64 = Base64.getDecoder()
        val plaintext =
            decryptPush(
                key = base64.decode("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="),
                nonce = base64.decode("oKGio6Slpqeoqaqr"),
                ciphertext =
                    base64.decode(
                        "nToKD3/6Lp0JDOm3JUDiuh/CPDK+lS8N/2ZP6BriESPoVCrOjQ5xTyryTawrQKGLdjlqahG1aQ0oMWUOxQ" +
                            "Ttko6eqgdfyIHPgc3Rd+K+49uqbsXQ6rL8CZ0cUfTCtTW7vttKhWnd4PXy+Spy8eGZREFyW4yYXOMcW6e7hMQ0" +
                            "gD6gY5JT8TH1dUMwiud3aKv07LzbCdGo2k5K7fmawaIWB+R6cNXPSHo0w2ZHAhu3xZUEBo35cRWAHK6gAkp+uC" +
                            "5gDQZ8+VDhi93DbXCyNzdjdu8yZsnjEAE6Fz78cw==",
                    ),
                deviceId = "00112233445566778899aabbccddeeff",
            )
        assertEquals(
            """{"v":1,"kind":"done","machineId":"m1","runId":"r1",""" +
                """"sessionPath":"/home/u/.omp/agent/sessions/x/1_a.jsonl","title":"Fix the parser",""" +
                """"subtitle":"devbox · Done","body":"All tests pass.","ts":1790000000000}""",
            String(plaintext, Charsets.UTF_8),
        )
    }
}
