# SPDX-License-Identifier: AGPL-3.0-or-later

# Ligne de commande Marten de l'extension, composée avec le cœur et
# l'interface comme dans une distribution :
# `crystal run manage.cr -- <commande>` (`genmigrations document`, `migrate`…).
require "partiduo-ui-bulma/partiduo_ui"
require "./src/partiduo-document"
require "./ui/bulma/bulma"
require "./config/settings/base"
require "./config/settings/**"
require "partiduo/cli"
require "./src/partiduo-document/cli"

Marten.setup
Marten::CLI.run
