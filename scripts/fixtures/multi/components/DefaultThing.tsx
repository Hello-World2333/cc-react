/**
 * Fixture: default export imported without braces. Receives a color passed
 * from App (an imported constant from lib/format.ts) and uses it as the text
 * color — a runtime hex STRING that the runtime's __color must parse.
 */

export default function DefaultThing({ accent }: { accent: string }) {
  return <Text style={{ color: accent }}>default export works</Text>;
}
