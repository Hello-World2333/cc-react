/**
 * Demo header: title + subtitle + live count.
 *
 * Multi-file demo: components live in their own files and are imported by
 * App.tsx. State lives in the container (App); this component receives the
 * current count as a prop.
 */

export function Header({ count }: { count: number }) {
  return (
    <Box
      style={{
        width: '100%',
        flexDirection: 'column',
        alignItems: 'center',
      }}
    >
      <Text style={{ fontSize: 3, color: '#ffffff', marginBottom: 4 }}>cc-react</Text>
      <Text style={{ fontSize: 1, color: '#6a6a78', marginBottom: 8 }}>
        React-style UI for CC + Tom's GPU
      </Text>
      <Text style={{ fontSize: 2, color: '#ffd866', marginBottom: 12 }}>Count: {count}</Text>
    </Box>
  );
}
