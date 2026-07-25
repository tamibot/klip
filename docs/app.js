// Klip landing — shared by index.html and features.html.

// Scroll reveal. FIRST on purpose: .js .reveal starts at opacity:0, so an
// uncaught error in any block above this one would leave the page blank.
// (prefers-reduced-motion is handled here AND in CSS — belt and braces.)
(function(){
  var els = document.querySelectorAll('.reveal');
  if(!els.length) return;
  var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  if(reduce || !('IntersectionObserver' in window)){
    els.forEach(function(el){ el.classList.add('in'); });
    return;
  }
  var io = new IntersectionObserver(function(entries){
    entries.forEach(function(en){
      if(en.isIntersecting){ en.target.classList.add('in'); io.unobserve(en.target); }
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -8% 0px' });
  els.forEach(function(el){ io.observe(el); });
})();

// Theme toggle — remembers the choice; defaults to the OS preference.
// aria-pressed is a real state, so it has to be right on load, not only after a click.
(function(){
  var root = document.documentElement;
  var KEY = 'klip-theme';
  try{
    var saved = localStorage.getItem(KEY);
    if(saved === 'light' || saved === 'dark') root.setAttribute('data-theme', saved);
  }catch(e){}
  var btn = document.getElementById('themeToggle');
  if(!btn) return;
  var os = matchMedia('(prefers-color-scheme: dark)');
  function current(){ return root.getAttribute('data-theme') || (os.matches ? 'dark' : 'light'); }
  function announce(){ btn.setAttribute('aria-pressed', String(current() === 'dark')); }
  announce();
  os.addEventListener('change', function(){ if(!root.getAttribute('data-theme')) announce(); });
  btn.addEventListener('click', function(){
    root.setAttribute('data-theme', current() === 'dark' ? 'light' : 'dark');
    try{ localStorage.setItem(KEY, current()); }catch(e){}
    announce();
  });
})();
