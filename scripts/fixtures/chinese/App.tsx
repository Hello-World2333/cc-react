/**
 * Chinese text fixture — exercises the opt-in custom-font path
 * (ui.setChineseFont, called by the test before start()).
 *
 * UTF-8 strings are encoded to single-byte slot strings before they reach
 * drawText/getTextLength; CJK glyphs are registered lazily from the binary
 * font file (scripts/fixtures/chinese/hanchan16.fnt); characters missing
 * from the font file (deliberately: 龙) fall back to the □ slot (0xFF).
 *
 * Headless test: scripts/test_chinese.lua
 *
 * Behaviors covered by the fixture:
 *   - Chinese Text nodes render through the slot-encoded path
 *   - a missing char (龙) renders as the □ fallback
 *   - Button with a Chinese label
 *   - Input with a Chinese placeholder
 *   - pasting Chinese into a focused input + char-aware Backspace/arrows
 */

function ChineseDemo() {
  const [text, setText] = useState('你好世界');
  const [pasted, setPasted] = useState('');

  return (
    <Panel
      style={{
        width: '100%',
        height: '100%',
        backgroundColor: '#131318',
        padding: 8,
        flexDirection: 'column',
      }}
    >
      <Text style={{ color: '#ffffff', fontSize: 2 }}>{text}</Text>
      <Text style={{ color: '#ffd866' }}>点阵字体渲染</Text>
      <Text style={{ color: '#7ec8ff' }}>龙</Text>
      <Button
        label="确认"
        onClick={() => setText('测试中文')}
        style={{ width: 80, height: 28, marginTop: 8 }}
      />
      <Input
        value={pasted}
        onChange={setPasted}
        placeholder="请输入"
        style={{ width: 220, height: 24, marginTop: 8 }}
      />
    </Panel>
  );
}

render(<ChineseDemo />);
