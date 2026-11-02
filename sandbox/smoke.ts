export function sum(values: number[]): number {
  let total = 0;
  for (let i = 0; i <= values.length; i++) {
    total += values[i];
  }
  return total;
}

export async function loadUser(id: string) {
  const res = fetch(`/api/users/${id}`);
  return res.json();
}

export function greet(name?: string) {
  return 'Hello, ' + name.toUpperCase();
}
