/**
 * Input tab — the keyboard showcase: three controlled <Input> fields with
 * placeholders, click-to-focus (cursor at the click), built-in editing
 * (insert/Backspace/Delete/arrows/Home/End), Enter firing onSubmit, and
 * Tab / Shift+Tab cycling focus across all three inputs. `onKey` reports raw
 * GLFW key codes (Enter 257 / Tab 258 / Backspace 259 / Left 263 ...), and
 * the message field shows the long-text behavior: the text scrolls
 * horizontally inside the box to keep the cursor visible.
 */

import { ACCENT, DIM, FAINT } from '../lib/theme';

export function InputTab() {
  const [name, setName] = useState('');
  const [note, setNote] = useState('');
  const [message, setMessage] = useState('');
  const [submits, setSubmits] = useState(0);
  const [lastName, setLastName] = useState('');
  const [lastKey, setLastKey] = useState(-1);

  return (
    <Box style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
      <Text style={{ fontSize: 1, color: FAINT, marginBottom: 4 }}>keyboard input + focus</Text>

      <Text style={{ fontSize: 1, color: DIM }}>name:</Text>
      <Input
        value={name}
        onChange={setName}
        placeholder="your name"
        style={{ width: 150, height: 22, marginTop: 2, marginBottom: 6 }}
        onSubmit={() => {
          setSubmits(submits + 1);
          setLastName(name);
        }}
        onKey={(k, up) => {
          if (!up) setLastKey(k);
        }}
      />

      <Text style={{ fontSize: 1, color: DIM }}>note:</Text>
      <Input
        value={note}
        onChange={setNote}
        placeholder="a note"
        style={{ width: 150, height: 22, marginTop: 2, marginBottom: 6 }}
        onSubmit={() => {
          setSubmits(submits + 1);
          setLastName(note);
        }}
      />

      <Text style={{ fontSize: 1, color: DIM }}>message:</Text>
      <Input
        value={message}
        onChange={setMessage}
        placeholder="long text scrolls in the box"
        style={{ width: 150, height: 22, marginTop: 2, marginBottom: 6 }}
      />

      <Text style={{ fontSize: 1, color: ACCENT }}>
        {lastName.length > 0
          ? 'hello, ' + lastName + '!'
          : name.length > 0
            ? 'typing: ' + name
            : 'click + type, Enter to submit'}
      </Text>
      <Text style={{ fontSize: 1, color: DIM, marginTop: 2 }}>submits: {submits}</Text>
      <Text style={{ fontSize: 1, color: DIM }}>last key: {lastKey}</Text>
      <Text style={{ fontSize: 1, color: FAINT, marginTop: 4 }}>Tab / Shift+Tab cycles focus</Text>
    </Box>
  );
}
