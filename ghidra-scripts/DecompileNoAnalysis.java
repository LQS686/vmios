// Import without analysis, then disassemble and decompile only the requested
// functions (address or containing address). Enough for symbol-rich dylibs.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.disassemble.Disassembler;

public class DecompileNoAnalysis extends GhidraScript {
    @Override
    public void run() throws Exception {
        DecompInterface ifc = new DecompInterface();
        ifc.toggleCCode(true);
        ifc.toggleSyntaxTree(true);
        if (!ifc.openProgram(currentProgram)) {
            println("decompiler openProgram failed: " + ifc.getLastMessage());
            return;
        }
        for (String arg : getScriptArgs()) {
            Address addr = currentProgram.getAddressFactory()
                .getDefaultAddressSpace().getAddress(arg);
            Function f = getFunctionAt(addr);
            if (f == null) {
                try {
                    Disassembler dis = Disassembler.getDisassembler(
                        currentProgram, monitor, null);
                    dis.disassemble(addr, null, true);
                } catch (Exception e) {
                    println("disassemble failed at " + arg + ": " + e);
                }
                f = createFunction(addr, null);
            }
            if (f == null) {
                f = getFunctionContaining(addr);
            }
            if (f == null) {
                println("=== no function at " + arg);
                continue;
            }
            DecompileResults res = ifc.decompileFunction(f, 180, monitor);
            println("=== " + f.getName() + " @ " + f.getEntryPoint());
            if (res != null && res.decompileCompleted()) {
                println(res.getDecompiledFunction().getC());
            } else {
                println("decompile failed: " + (res == null ? "null" : res.getErrorMessage()));
            }
        }
        ifc.dispose();
    }
}
