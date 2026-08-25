const fs = require("fs")
const path = require("path")
const vm = require("vm")

const ROOT = path.dirname(__dirname)

// The QML JS modules are plain scripts with a `.pragma library` directive that
// only the QML engine understands. Stripping it leaves ordinary JavaScript,
// which runs in a vm context so the tests exercise exactly the file the shell
// loads rather than a copy.
function load(relativePath) {
  const source = fs
    .readFileSync(path.join(ROOT, relativePath), "utf8")
    .replace(/^\.pragma library\s*$/m, "")
  const context = {}
  vm.createContext(context)
  vm.runInContext(source, context)
  return context
}

module.exports = { load, ROOT }
