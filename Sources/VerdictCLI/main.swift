import Foundation

setvbuf(stdout, nil, _IOFBF, 1 << 16)
let code = await CLI().run(Array(CommandLine.arguments.dropFirst()))
fflush(stdout)
exit(code)
