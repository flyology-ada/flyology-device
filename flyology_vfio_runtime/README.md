# flyology_vfio_runtime

Waiting for a VFIO interrupt on a Flyology event loop.

One package, `Flyology_VFIO.Flyology_Runtime`, holding one type. It exists
so that a crate which binds an ioctl does not have to decide how the
programs using it spend their time.

## Why it is a separate crate

`flyology_vfio` declares `Interrupts.Waiter` and ships a `Blocking_Waiter`
over `poll(2)`. That covers a program with no event loop, and it is
deliberately a duplicate of what `Flyology.IO.Wait` already does better.
What it cannot do is suspend one task and let its siblings run, because
knowing how to do that means depending on a runtime — which brings a
`GPL-3.0-or-later` component and a custom Ada runtime with it, neither of
which belongs in a crate whose job is to send an ioctl.

So the dependency lives here, alone, and everything else in the repository
stays free of it. Anything wanting both takes this crate.

## Why the package is a child of `Flyology_VFIO`

The type implements `Flyology_VFIO.Interrupts.Waiter`, so it belongs in that
namespace. Putting it under the runtime's root instead would have had
`Flyology.*` claiming a VFIO concept it knows nothing about.

One consequence: a cross-crate child appears in neither the parent crate's
generated documentation nor a standalone build of it. That is normal, and
noted here so it does not read as a gap.

## Both lanes, one waiter

The reason this is worth having is not only ergonomics.
`Flyology.IO.Wait` decides for itself which kind of task is calling: a
lightweight task suspends on its event loop and its siblings keep running,
while a native task blocks its own thread in `poll`. A driver written
against `Runtime_Waiter` therefore does not need to know which it is in.

`Flyology_VFIO.Flyology_Runtime.On_Event_Loop` answers that question when a
driver does want to know — for instance to poll for a while before
sleeping, which is what a latency-sensitive driver does.

It also carries a single deadline across interrupted waits, which
`Blocking_Waiter` does not.

## Using it

```ada
declare
   Waiting : Adapter.Runtime_Waiter;
   Done    : Interrupts.Event;
begin
   Interrupts.Open (Done);
   Interrupts.Enable (Device, Interrupts.MSI_X,
                      [0 => Interrupts.Descriptor (Done)]);

   Submit_Work;

   if Waiting.Wait_For (Done, Timeout => 1.0) then
      Collect_Completions;
   end if;
end;
```

`Wait_For_Any` takes several descriptors and returns the lowest ready
index, which is what a driver with one vector per queue needs. It refuses a
set larger than `Maximum_Watched` rather than silently watching a prefix,
because a driver that believed it was watching eight queues and was
watching four would stall on the other four with nothing to say why.

## Testing

```sh
./scripts/test.sh
```

No device is needed. VFIO delivers an interrupt by making an eventfd
readable, and an eventfd can be made readable by writing to it, so the
waiter is tested against exactly what it will see in service. The suite
checks both lanes: the main task confirms it is native, and a task spawned
into a `Flyology.Task_Scopes` scope confirms it is lightweight, with the
same waiter used from each.

What the tests do not establish is that a lightweight wait yields its event
loop to siblings rather than monopolising it. That is the runtime's own
contract, and showing it would take a test built around scheduling rather
than around waiting.

## Licence

MIT OR Apache-2.0. Note that using this crate pulls in the `flyology`
runtime, whose licence is `(MIT OR Apache-2.0) AND GPL-3.0-or-later WITH
GCC-exception-3.1`. That is the reason this is a separate crate.
