# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/**"
require "./services/**"
require "./api/**"

# Extension DOCUMENT de Partiduo, successeur de `noalyss_document` (NDER,
# NDC) de NOALYSS : la boîte unique « Justificatifs à traiter » (ADR-005 D8).
# Même plan qu'une application du cœur (DECISIONS C1) : `manifest.cr`,
# `models/`, `migrations/`, `services/` (interne), `api/` (contrat public
# `Document::Api`), `locales/`.
module Document
  VERSION = "0.1.0"

  # Code du registre (ADR-003 D2) : `document` dans `PARTIDUO_MODULES`.
  CODE = "DOCUMENT"

  # Application Marten du métier : modèles (tables `document_*`), migrations
  # et libellés.
  class App < Marten::App
    label "document"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Partiduo::INSTALLED_APPS`.
  INSTALLED_APPS = [Document::App] of Marten::Apps::Config.class
end
