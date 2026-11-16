# Short live Soniox probe

On 2026-11-16, one serial Soniox real-time v6 request streamed 5.3505625 seconds of locally generated synthetic speech. The existing spike harness and its frozen dependency lock paced 16 kHz mono PCM in 100 ms chunks, finalized the stream and closed the connection. It returned 25 responses and a finished marker. No speech or sound from the user was needed, and no physical microphone was used.

Spoken synthetic source: “Legato test. The boat leaves the harbour on Friday. Please bring the blue notebook.” Recognized final text: “Lugato test. The boat leaves the harbor on Friday. Please bring the blue notebook.” The brand-name error is retained in the response artifact; this is transport/recognition evidence for one synthetic clip, not a general quality claim.

The exact timestamped provider responses are in `live-soniox-synthetic.json`, suitable for the existing app's decoder replay. Replaying these responses on the phone is a separate field-route check, not proof that phone microphone audio traversed this same connection. The local generated audio, keys and raw operational logs remain in the private cache; no credentials are included in this artifact.
