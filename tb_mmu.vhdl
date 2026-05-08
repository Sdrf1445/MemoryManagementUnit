library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_mmu is
end tb_mmu;

architecture behavior of tb_mmu is

    -- Component Declaration for the Unit Under Test (UUT)
    component mmu
        Port (
            clk       : in  std_logic;
            rst       : in  std_logic;
            virt_addr : in  std_logic_vector(15 downto 0);
            rw        : in  std_logic;
            req       : in  std_logic;
            phys_addr : out std_logic_vector(11 downto 0);
            ready     : out std_logic;
            fault     : out std_logic
        );
    end component;

    -- Inputs
    signal clk       : std_logic := '0';
    signal rst       : std_logic := '0';
    signal virt_addr : std_logic_vector(15 downto 0) := (others => '0');
    signal rw        : std_logic := '0';
    signal req       : std_logic := '0';

    -- Outputs
    signal phys_addr : std_logic_vector(11 downto 0);
    signal ready     : std_logic;
    signal fault     : std_logic;

    constant CLK_PERIOD : time := 10 ns;

begin

    -- Instantiate the Unit Under Test (UUT)
    uut: mmu
        Port map (
            clk       => clk,
            rst       => rst,
            virt_addr => virt_addr,
            rw        => rw,
            req       => req,
            phys_addr => phys_addr,
            ready     => ready,
            fault     => fault
        );

    -- Clock process definitions
    clk_process : process
    begin
        clk <= '0';
        wait for CLK_PERIOD/2;
        clk <= '1';
        wait for CLK_PERIOD/2;
    end process;

    -- Stimulus process
    stim_proc: process
    begin
        -- Reset
        rst <= '1';
        wait for 30 ns;
        rst <= '0';
        wait for 20 ns;

        ------------------------------------------------------
        -- Test 1: Access virtual address 0x0102 (TLB first miss + page table hit)
        ------------------------------------------------------
        wait until rising_edge(clk);
        virt_addr <= x"0302";
        rw        <= '0';
        req       <= '1';

        wait until rising_edge(clk);
        req <= '0';

        wait until ready = '1';
        wait for 2*CLK_PERIOD;

        ------------------------------------------------------
        -- Test 2: Access virtual address 0x0304 (TLB miss + page table hit + try to write on a readonly page)
        ------------------------------------------------------
        wait until rising_edge(clk);
        virt_addr <= x"0104";
        rw        <= '1';
        req       <= '1';

        wait until rising_edge(clk);
        req <= '0';

        wait until ready = '1';
        wait for 2*CLK_PERIOD;

        ------------------------------------------------------
        -- Test 3: Access virtual address 0x0506 (TLB miss + page table miss ? fault) -- invalid
        ------------------------------------------------------
        wait until rising_edge(clk);
        virt_addr <= x"0206";
        rw        <= '1';
        req       <= '1';

        wait until rising_edge(clk);
        req <= '0';

        wait until ready = '1';
        wait for 2*CLK_PERIOD;
		
		-- check if TLB shortens the time
		wait until rising_edge(clk);
        virt_addr <= x"0302";
        rw        <= '0';
        req       <= '1';

        wait until rising_edge(clk);
        req <= '0';

        wait until ready = '1';
        wait for 2*CLK_PERIOD;
		
        -- Not allowed (permission denied) 
			
		wait until rising_edge(clk);
        virt_addr <= x"0A06";
        rw        <= '1';
        req       <= '1';

        wait until rising_edge(clk);
        req <= '0';

        wait until ready = '1';
        wait for 2*CLK_PERIOD;

        wait;
    end process;

end behavior;
