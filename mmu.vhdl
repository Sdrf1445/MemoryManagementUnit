library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mmu is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        -- Request from CPU
        req       : in  std_logic;                        -- request valid
        virt_addr : in  std_logic_vector(15 downto 0);    -- virtual address => 8 bit VPN + 8 bit Page Offset
        rw        : in  std_logic;                        -- '0' = read, '1' = write
        -- Response to CPU
        ready     : out std_logic;                        -- translation ready (one cycle after)
        phys_addr : out std_logic_vector(11 downto 0);    -- physical address if ready and no fault
        fault     : out std_logic                         -- 1 = protection/page fault
    );
end entity mmu;

architecture Behavioral of mmu is

    -- Page table entry
    type pte_t is record
        valid : std_logic;
        read_allow  : std_logic;
        write_allow : std_logic;
        ppn   : std_logic_vector(3 downto 0); -- physical page number => 4bit => 16 physical pages
    end record;

    -- Page table: 256 entries (indexed by VPN 8-bit)
    type page_table_t is array (0 to 255) of pte_t;
    signal page_table : page_table_t;

    -- Simple 4-entry fully-associative TLB
    constant TLB_ENTRIES : integer := 4;
    type tlb_entry_t is record
        valid : std_logic;
        tag   : std_logic_vector(7 downto 0);  -- VPN => search VPN amonge these
        ppn   : std_logic_vector(3 downto 0);
        read_allow  : std_logic;
        write_allow : std_logic;
    end record;
    type tlb_t is array (0 to TLB_ENTRIES-1) of tlb_entry_t;
    signal tlb : tlb_t;

    -- FIFO pointer for replacement
    signal tlb_rr_ptr : integer range 0 to TLB_ENTRIES-1 := 0;

    -- Internal signals
    signal vpn       : std_logic_vector(7 downto 0);
    signal offset    : std_logic_vector(7 downto 0);
	-- for later: if valid: phys_addr <= ppn & offset

    signal tlb_hit   : std_logic := '0';
    signal tlb_ppn   : std_logic_vector(3 downto 0) := (others => '0');
    signal tlb_read_allow  : std_logic := '0';
    signal tlb_write_allow : std_logic := '0';

    -- State for multi-cycle miss handling
    signal pending_req : std_logic := '0';
    signal pending_vpn : std_logic_vector(7 downto 0) := (others => '0');
    signal pending_rw  : std_logic := '0';
    signal resp_ready  : std_logic := '0';
    signal resp_fault  : std_logic := '0';
    signal resp_phys   : std_logic_vector(11 downto 0) := (others => '0');

begin

    -- split virtual address
    vpn    <= virt_addr(15 downto 8);
    offset <= virt_addr(7 downto 0);

    ----------------------------------------------------------------
    -- TLB lookup (combinational) using local variables then
    -- update shared signals at the end (to avoid latches/multiple drivers)
    ----------------------------------------------------------------
    tlb_lookup : process(vpn, tlb)
        variable v_hit : std_logic := '0';
        variable v_ppn : std_logic_vector(3 downto 0) := (others => '0');
        variable v_r   : std_logic := '0';
        variable v_w   : std_logic := '0';
        variable i     : integer;
    begin
        v_hit := '0';
        v_ppn := (others => '0');
        v_r := '0';
        v_w := '0';
        for i in 0 to TLB_ENTRIES-1 loop
            if tlb(i).valid = '1' and tlb(i).tag = vpn then
                v_hit := '1';
                v_ppn := tlb(i).ppn;
                v_r := tlb(i).read_allow;
                v_w := tlb(i).write_allow;
                exit;
            end if;
        end loop;
        tlb_hit <= v_hit;
        tlb_ppn <= v_ppn;
        tlb_read_allow <= v_r;
        tlb_write_allow <= v_w;
    end process;

    ----------------------------------------------------------------
    -- Main state machine: synchronous with reset (clk, rst)
    ----------------------------------------------------------------
    main_proc : process(clk, rst)
        variable pte : pte_t;
        variable i   : integer;
    begin
        if rst = '1' then
            -- default: clear page table
            for i in 0 to 255 loop
                page_table(i).valid <= '0';
                page_table(i).read_allow <= '0';
                page_table(i).write_allow <= '0';
                page_table(i).ppn <= (others => '0');
            end loop;

            -- Example mappings (for testbench) #CheckThis
            page_table(0).valid <= '1';
            page_table(0).read_allow <= '1';
            page_table(0).write_allow <= '1';
            page_table(0).ppn <= "0000";

            page_table(1).valid <= '1';
            page_table(1).read_allow <= '1';
            page_table(1).write_allow <= '0';
            page_table(1).ppn <= "0001";

            page_table(2).valid <= '0';

            page_table(3).valid <= '1';
            page_table(3).read_allow <= '1';
            page_table(3).write_allow <= '1';
            page_table(3).ppn <= "0010";
			
			page_table(10).valid <= '1';
			page_table(10).read_allow <= '0';
			page_table(10).write_allow <= '0';
            page_table(10).ppn <= "0100"; -- just to show there is no order in play
			

            -- init TLB entries to invalid
            for i in 0 to TLB_ENTRIES-1 loop
                tlb(i).valid <= '0';
                tlb(i).tag   <= (others => '0');
                tlb(i).ppn   <= (others => '0');
                tlb(i).read_allow <= '0';
                tlb(i).write_allow <= '0';
            end loop;
            tlb_rr_ptr <= 0;

            -- clear pending/response
            pending_req <= '0';
            resp_ready <= '0';
            resp_fault <= '0';
            resp_phys <= (others => '0');

        elsif rising_edge(clk) then	  
            -- default clear ready unless set below
            resp_ready <= '0';
            resp_fault <= '0';

            -- capture new request if none pending
            if pending_req = '0' then
                if req = '1' then
                    -- check TLB immediately (tlb_hit is combinational)
                    if tlb_hit = '1' then
                        -- TLB hit: check permission
                        if ((rw = '1' and tlb_write_allow = '0') or (rw = '0' and tlb_read_allow = '0')) then
                            -- write/read not allowed -> protection fault
                            resp_fault <= '1';
                            resp_ready <= '1';
                            resp_phys <= (others => '0');
                        else
                            -- allowed: construct physical address and respond
                            resp_phys <= tlb_ppn & offset;
                            resp_ready <= '1';
                            resp_fault <= '0';
                        end if;
                    else
                        -- TLB miss: start page table lookup next cycle
                        pending_req <= '1';
                        pending_vpn <= vpn;
                        pending_rw <= rw;
                    end if;
                end if;
            else
                -- pending: read PTE for pending_vpn (one-cycle miss service)
                pte := page_table(to_integer(unsigned(pending_vpn)));
                if pte.valid = '0' then
                    -- page fault (invalid)
                    resp_fault <= '1';
                    resp_ready <= '1';
                    resp_phys <= (others => '0');
                else
                    -- PTE valid; check permissions
                    if ((pending_rw = '1' and pte.write_allow = '0') or (pending_rw = '0' and pte.read_allow = '0')) then
                        -- write/read not allowed
                        resp_fault <= '1';
                        resp_ready <= '1';
                        resp_phys <= (others => '0');
                    else
                        -- allowed: create physical addr, update TLB (FIFO replacement), respond
                        resp_phys <= pte.ppn & offset;
                        resp_ready <= '1';
                        resp_fault <= '0';
                        -- update TLB: replace at tlb_rr_ptr (rttttt!)
                        tlb(tlb_rr_ptr).valid <= '1';
                        tlb(tlb_rr_ptr).tag   <= pending_vpn;
                        tlb(tlb_rr_ptr).ppn   <= pte.ppn;
                        tlb(tlb_rr_ptr).read_allow <= pte.read_allow;
                        tlb(tlb_rr_ptr).write_allow <= pte.write_allow;
                        -- advance pointer (loop - wrap around!)
                        if tlb_rr_ptr = TLB_ENTRIES-1 then
                            tlb_rr_ptr <= 0;
                        else
                            tlb_rr_ptr <= tlb_rr_ptr + 1;
                        end if;
                    end if;
                end if;
                -- done with pending ^_^
                pending_req <= '0';
            end if;
        end if;
    end process;

    -- connect outputs (map responses to the outputs)
    ready <= resp_ready;
    fault <= resp_fault;
    phys_addr <= resp_phys;

end architecture Behavioral;
