# GravityNotch (BoringNotch Pro Edition)

> **Notice de licence & crédits (GPL-3.0)** : Ce projet est un fork enrichi basé sur [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch), distribué sous licence libre **GNU General Public License v3.0 ([`LICENSE`](LICENSE))**. Tous les droits et crédits de l'architecture d'origine reviennent aux auteurs de *Boring Notch*.

**GravityNotch** transforme l'encoche (Notch) de votre MacBook en un véritable centre de contrôle dynamique de style *Dynamic Island*, combinant la stabilité et le design natif de **Boring Notch** avec une suite complète d'outils de productivité, de capture OCR, de contrôle média avancé et de suivi d'agents IA.

---

## ✨ Nouvelles fonctionnalités ajoutées dans cette édition

### 1. 🔒 Lock Screen Media Widget + Live Karaoke Lyrics (`SkyLightWindow`)
- **Panneau Liquid Glass sur l'écran verrouillé macOS** (`396×236`) affiché par-dessus l'écran de verrouillage grâce au framework privé `SkyLight`.
- **Paroles synchronisées en direct (Live Lyrics 3 lignes)** : affiche la ligne précédente estompée, la ligne chantée en blanc lumineux gras synchronisée à `0.25s` via LRCLIB (avec nettoyage automatique des suffixes `(Slowed)` / `(Remix)`) ou les paroles intégrées d'Apple Music, ainsi que la ligne suivante.

### 2. 🎵 Playing Next (File d'attente Apple Music interactive)
- Bouton **`music.note.list`** intégré directement aux contrôles du lecteur musical.
- Bascule fluide dans l'onglet **Home** entre le **Calendrier Apple** et la liste **Playing Next**.
- Clic direct sur n'importe quel titre à venir pour le jouer immédiatement, ou bouton **`arrow.up.to.line`** pour le remonter en tête de file.

### 3. 🔆 System HUDs macOS Tahoe (Interception matérielle Triple-Couche `< 1 µs`)
- Remplacement complet des bulles système macOS (Volume, Luminosité écran, Rétroéclairage clavier et **Caps Lock HUD**) par une animation fluide directement dans l'encoche (*Dynamic Island*).
- Compatible **macOS 26 Tahoe** : interception simultanée sur `.cghidEventTap`, `.cgSessionEventTap` et `.cgAnnotatedSessionEventTap` sur une file `.userInteractive` dédiée avec lecture directe des champs `CGEvent` (`99` et `149`) sans latence ni double HUD.

### 4. 🔍 Text Capture (Screen OCR) & Element Capture
- Bouton **`text.viewfinder`** dans l'en-tête de l'encoche :
  - **Clic gauche** : sélectionne une zone de l'écran et extrait instantanément le texte via Apple Vision (`VNRecognizeTextRequest`) directement dans le presse-papiers.
  - **Clic droit** : capture une zone ou une fenêtre/élément détouré directement vers le **Shelf**.

### 5. 📋 Onglet `Clips` (Gestionnaire d'historique du Presse-papiers)
- Surveillance en temps réel de `NSPasteboard.general` (texte, liens, fichiers, codes couleurs hexadécimaux avec aperçu couleur).
- Recherche instantanée, épinglage (*Pin*), copie en un clic et envoi direct d'un élément vers le **Shelf**.

### 6. ✨ Onglet `Agents` (Moniteur Live Antigravity & Live Activity)
- Suivi en temps réel des sessions d'agent IA (`transcript.jsonl`) :
  - Jauge de **Context / Quota** sur la fenêtre de `1M` tokens (`input_tokens + cache_read_tokens`).
  - Taux de **Cache Hit %**, tokens générés (`output_tokens`), numéro d'étape (`Step #`), nombre de fichiers modifiés et flux d'outils en direct (*Live Tool Feed*).
- **Live Activity** sur l'encoche fermée indiquant l'activité de l'agent et le pourcentage de contexte.

### 7. ☕ Mode Caffeine, 🎧 Sortie Audio & ⚡ Actions Rapides Shelf
- **Caffeine (`IOKit` Power Assertion)** : empêche la mise en veille du Mac (infini, 15 min, 30 min, 1 h, 2 h) depuis l'en-tête de l'encoche.
- **Sélecteur de sortie audio (`CoreAudio`)** : bascule instantanément entre les haut-parleurs du MacBook, AirPods ou écrans externes.
- **Actions rapides Shelf** : extraction **OCR** sur les images déposées, compression **ZIP**, conversion **PNG**, suppression d'arrière-plan (**BG** via `VNGenerateForegroundInstanceMaskRequest`) et partage instantané via lien **`0x0.st`**.

---

## 🛠️ Compilation & Installation depuis les sources

### Prérequis
- macOS 14 Sonoma, macOS 15 Sequoia ou **macOS 26 Tahoe**
- Xcode 16+

### Compiler et installer dans `/Applications`

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" build
```

---

## 📄 Licence & Remerciements

- Distribué sous licence **GNU General Public License v3.0** — voir le fichier [`LICENSE`](LICENSE).
- Basé sur le projet open-source [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch).
