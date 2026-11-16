# Age rating questionnaire

App Store Connect → App Information → Age Rating. The wording of the questions changes
from time to time; answer by meaning, using this table.

## Content descriptors

| Question | Answer |
|---|---|
| Cartoon or fantasy violence | None |
| Realistic violence | None |
| Sexual content or nudity | None |
| Profanity or crude humour | None |
| Alcohol, tobacco or drug references | None |
| Mature or suggestive themes | None |
| Horror or fear themes | None |
| Medical or treatment information | None |
| Gambling, simulated gambling, contests | None |

These describe what the app itself contains. The app ships no such content.

## Capabilities

| Question | Answer |
|---|---|
| Unrestricted web access | No |
| User-generated content shared between users | No |
| Messaging or chat between users | No |
| Advertising | No |
| Loot boxes | No |
| **AI assistant or chatbot that generates content** | **Yes** |
| Parental controls or age assurance in the app | No |

## Expected result

Answering "Yes" to the AI question means the rating will be above 4+. Accept the rating
App Store Connect calculates; do not override it downwards. A general-purpose chat
model can produce mature text if asked, and App Review checks that the rating admits this.

If a field asks how often generated content could be mature, choose
**Infrequent/Mild**: the app has no personas or prompts aimed at such content.

## Keep it true

The built-in personas must stay general purpose. A companion or romantic persona would
move the app to the highest age tier.
