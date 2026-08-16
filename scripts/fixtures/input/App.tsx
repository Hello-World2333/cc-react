/**
 * Keyboard input fixture — exercises the <Input> component and focus
 * management in isolation (headless test: scripts/test_input.lua).
 *
 * Two inputs (name + note) so Tab / Shift+Tab focus cycling can be asserted;
 * a summary line shows the live values so tree assertions are readable.
 *
 * Behaviors covered by the fixture:
 *   - placeholder shown while the value is empty
 *   - click-to-focus with the cursor placed at the clicked character
 *   - typing inserts at the cursor; Backspace/Delete edit around it
 *   - Home/End/arrows move the cursor
 *   - Enter fires onSubmit
 *   - Tab / Shift+Tab cycle focus between the two inputs
 *   - clicking outside blurs (focus ring + cursor disappear)
 */

function InputDemo() {
  const [name, setName] = useState('');
  const [note, setNote] = useState('');
  const [submits, setSubmits] = useState(0);
  const [last, setLast] = useState('none');
  const [lastKey, setLastKey] = useState(-1);

  return (
    <Panel
      style={{
        width: '100%',
        height: '100%',
        backgroundColor: '#131318',
        padding: 10,
        flexDirection: 'column',
        alignItems: 'flex-start',
      }}
    >
      <Text style={{ color: '#8a8a95' }}>name:</Text>
      <Input
        value={name}
        onChange={setName}
        placeholder="your name"
        style={{ width: 160, height: 24, marginTop: 4 }}
        onSubmit={() => {
          setSubmits(submits + 1);
          setLast(name);
        }}
        onKey={(k, up) => {
          if (!up) setLastKey(k);
        }}
      />

      <Text style={{ color: '#8a8a95', marginTop: 12 }}>note:</Text>
      <Input
        value={note}
        onChange={setNote}
        placeholder="a note"
        style={{ width: 160, height: 24, marginTop: 4 }}
        onSubmit={() => {
          setSubmits(submits + 1);
          setLast(note);
        }}
      />

      <Text style={{ color: '#7ec8ff', marginTop: 12 }}>name: {name.length > 0 ? name : '(empty)'} | note: {note.length > 0 ? note : '(empty)'}</Text>
      <Text style={{ color: '#7ec8ff', marginTop: 4 }}>submits: {submits} last: {last}</Text>
      <Text style={{ color: '#8a8a95', marginTop: 4 }}>lastkey: {lastKey}</Text>
    </Panel>
  );
}

render(<InputDemo />);
