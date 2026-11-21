# GravityNotch Roadmap

Ce document recense les évolutions en cours, les prochaines améliorations produit et les correctifs issus de l’audit du code (traités par lots ciblés pour éviter toute régression).

---

## En cours / Implémenté

- **Live Activity AirPods & Audio Bluetooth dans l’encoche**
  - Détection temps réel de la connexion / bascule vers des AirPods ou un casque Bluetooth via `CoreAudio` (`kAudioHardwarePropertyDefaultOutputDevice`, sans invite d’autorisation Bluetooth).
  - Identification du modèle (AirPods 1/2/3/4, AirPods Pro, AirPods Max, Beats, casques génériques) et lecture asynchrone des niveaux de batterie (Gauche / Droite / Boîtier).
  - Animation Dynamic Island dans la notch fermée avec anneaux de batterie animés + bouton d’aperçu et réglage dédié dans *Réglages → HUDs*.
- **Synchronisation temps réel du volume sur périphériques Bluetooth / AirPods**
  - Ré-attachement des écouteurs CoreAudio (`kAudioDevicePropertyVolumeScalar`, `VirtualMainVolume`, `kAudioDevicePropertyMute`) lors du changement de périphérique de sortie audio (`VolumeManager`).
  - Affichage du HUD de volume dans la notch lorsque le son est modifié directement depuis les AirPods (tige) ou le Centre de contrôle macOS.

---

## Prochains correctifs techniques (issus de l’audit, par lots)

### Lot 1: Crashs UI & Sécurité / Fichiers
- [ ] Valider l’URL dans la feuille *Add new visualizer* (`SettingsView.swift`) au lieu de `URL(string: url)!`, et débloquer l’usage des visualiseurs custom si pertinent.
- [ ] Corriger l’index d’insertion dans `ImageProcessingService.createPDF(from:)` (`pdfDocument.pageCount` au lieu de `index` issu d’`enumerated()`).
- [ ] Remplacer le force-cast `as! Data` dans `BoringViewCoordinator.sneakPeekEvent(_:)`.
- [ ] Sécuriser `QuickShareService` quand la vue hôte est `nil` (éviter le blocage de `SharingStateManager.preventNotchClose`) et ajouter une confirmation + garde-fou taille/en-tête pour l’upload `0x0.st`.
- [ ] Restreindre `Info.plist` avec `NSAllowsLocalNetworking` (pour YouTube Music sur `localhost:26538`) au lieu de `NSAllowsArbitraryLoads`.
- [ ] Placer les captures d’écran temporaires (`ScreenCaptureOCRService`) dans des sous-dossiers UUID isolés, nettoyer `workingDir` en cas d’échec `zip`, et ajouter `--` devant le nom de fichier passé à `/usr/bin/zip`.

### Lot 2: Contrôleurs Média & Paroles
- [ ] Corriger l’interpolation AppleScript dans `AppleMusicController.setFavorite(_:)` (le bouton cœur ne s’appliquait pas avec ce contrôleur) et éviter les retries artwork quand Music est arrêté (`"Not Playing"`).
- [ ] Corriger `MusicManager.updateFromPlaybackState`: mettre à jour `lastArtworkTitle` / `lastArtworkArtist` / `lastArtworkAlbum` même lorsque la pochette reste identique entre deux pistes d’un même album (évite les requêtes `lrclib.net` et animations en boucle).
- [ ] Annuler les tâches concurrentes de récupération de paroles / décodage de pochette dans `MusicManager`, et encoder proprement `&` / `+` dans les requêtes `lrclib.net`.
- [ ] Corriger `YouTubeMusicController`: ne plus annuler `appStateObserver` quand YouTube Music se ferme (pour détecter sa réouverture), exécuter `startPeriodicUpdates` sur un `RunLoop` actif (`@MainActor`), ajouter `deinit` et ne réinitialiser `reconnectDelay` qu’après connexion effective.
- [ ] Éviter l’écrasement d’état par un snapshot obsolète dans `SpotifyController` lors du téléchargement de pochette, reprendre la continuation `JSONLinesPipeHandler.readData()` sur `close()`, et sécuriser les délimiteurs / timeouts dans `PlayingNextManager`.

### Lot 3: Système, Multi-écrans & Finitions
- [ ] Synchroniser les accès concurrents dans `MediaKeyInterceptor`, stopper/ralentir `permissionWatchdog` quand le HUD est désactivé, et éviter l’appel synchrone bloquant au sous-processus `--check-post-event` sur `@MainActor`.
- [ ] Nettoyer proprement tous les observers `windowScreenDidChangeObserver` en mode multi-écrans (`AppDelegate`) et attendre le check asynchrone `isNowPlayingDeprecated` au lancement.
- [ ] Honorer le réglage `autoScrollToNextEvent` dans `BoringCalendar`, rafraîchir le sélecteur d’écran à chaud dans *Réglages → Général*, et couper le timer `AntigravityAgentMonitor` lorsque les fonctionnalités Agents sont désactivées.

---

## Roadmap Produit (Futures fonctionnalités)

- **Audio & Live Activities**
  - Afficher l’état ANC / Transparence et le basculement rapide de sortie audio au clic sur la Live Activity AirPods.
  - Live Activity dédiée aux téléchargements navigateur (Safari / Chrome) en réactivant et fiabilisant l’onglet *Downloads*.
  - Indicateur discret Micro / Caméra / Partage d’écran actif dans l’encoche.
- **Clips & Shelf**
  - Prise en charge des images brutes copiées dans Clips (captures vers presse-papiers).
  - Chiffrement de l'historique Clips sauvegardé sur disque.
- **Qualité & Internationalisation**
  - Ajout d’une cible de tests unitaires (`XCTest`) pour `ClipboardHistoryManager`, `VolumeManager`, `TemporaryFileStorageService` et le parsing des sessions Agents.
  - Complétion des traductions communautaires (issues [#12](https://github.com/adrielakak/GravityNotch/issues/12)–[#15](https://github.com/adrielakak/GravityNotch/issues/15)).
